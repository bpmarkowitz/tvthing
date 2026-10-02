import type { BridgethingClient } from '@bridgething/client';
import type { ExtensionLink } from './link';

/**
 * Moving the picture costs a small hitch, and position reports carry a couple hundred
 * milliseconds of jitter, so smaller differences are left to the viewer's nudge.
 */
const DRIFT_THRESHOLD_MS = 300;
/** Consecutive out-of-sync checks before acting, so one jittery reading is ignored. */
const DRIFT_SAMPLES = 3;
/** Picture moves for slow drift are at most this frequent. */
const DRIFT_COOLDOWN_MS = 20_000;
/** A difference this large (e.g. the picture rebuffered) is fixed sooner. */
const JUMP_THRESHOLD_MS = 1_000;
const JUMP_COOLDOWN_MS = 4_000;
/** After starting or moving the picture, readings take a moment to settle. */
const SETTLE_MS = 2_000;
/** After a move, a miss larger than this is corrected straight away (a few times at most). */
const MISS_TOLERANCE_MS = 300;
const QUICK_RETRIES = 2;
const POLL_MS = 1_000;
/** How often the measured difference is logged, for troubleshooting sync. */
const REPORT_MS = 15_000;

interface HostReport {
  positionMs: number;
  ageMs: number;
  playing: boolean;
  at: number;
}

/**
 * The sound, played on the computer by Bridgething's host player from the same playlist as
 * the picture. The host player can't be moved once it's playing a live stream (seeks are
 * ignored), so the sound plays straight through and the picture follows it.
 *
 * The two players count position from different places (each from the first segment it
 * happened to load), so positions are compared as program-date-time: the picture's comes from
 * hls.js, and the host player's is its position plus the date where it started, which TV
 * Thing's extension records as it serves that player the playlist.
 */
export class Sound {
  private url: string | null = null;
  private sessionID: string | null = null;
  /** Program-date-time (Unix ms) of the host player's position 0, once the extension knows. */
  private origin: number | null = null;
  private host: HostReport | null = null;
  private settledAt: number | null = null;
  private aligned = false;
  private lastMoveAt = 0;
  private driftCount = 0;
  private offsetMs = 0;
  private lastReportAt = 0;
  /** Set after moving the picture, until where it landed has been checked. */
  private checkingMove = false;
  private retries = 0;
  /** Whether `onInSync` has run since the sound (or picture) last started. */
  private announced = false;

  constructor(
    private readonly client: BridgethingClient,
    private readonly link: ExtensionLink,
    private readonly log: (message: string) => void,
    /** Moves the picture by this many milliseconds (positive is later in the stream). */
    private readonly movePicture: (ms: number) => void,
    /** The picture has first lined up with the sound (or got as close as it will). */
    private readonly onInSync: () => void,
  ) {
    client.player.onSnapshot((reply) => this.record(reply.state.playback));
    window.setInterval(() => this.poll(), POLL_MS);
  }

  get isActive(): boolean {
    return this.url !== null;
  }

  /** Starts the sound from the playlist; `follow` then lines the picture up with it. */
  async play(url: string, sessionID: string): Promise<void> {
    this.url = url;
    this.sessionID = sessionID;
    this.origin = null;
    this.host = null;
    this.settledAt = null;
    this.aligned = false;
    this.checkingMove = false;
    this.announced = false;
    this.driftCount = 0;
    // The extension notes where the host player starts as it loads; forget the last load.
    await this.link.resetHostTimeline(sessionID).catch(() => {});
    if (this.url !== url) return;
    this.client.player.play({ uri: url, context: null }).catch((error: Error) => this.log(`Host player wouldn't play: ${error.message}`));
  }

  stop(): void {
    if (this.url === null) return;
    this.url = null;
    this.sessionID = null;
    this.host = null;
    this.client.player.pause().catch(() => {});
  }

  /** The picture is reloading; line it up with the sound again once it's back. */
  realign(): void {
    this.aligned = false;
    this.checkingMove = false;
    this.announced = false;
  }

  /** Positive plays the sound later than the picture. Applied at once. */
  setOffset(ms: number): void {
    if (ms === this.offsetMs) return;
    this.offsetMs = ms;
    this.aligned = false;
  }

  /**
   * Call regularly with the program-date-time of the frame on screen (null if unknown);
   * moves the picture when it has drifted from the sound.
   */
  follow(pictureDate: number | null, picturePlaying: boolean): void {
    const host = this.hostPosition();
    if (!this.url || !picturePlaying || pictureDate === null || this.origin === null || host === null || this.settledAt === null) return;
    if (Date.now() - this.settledAt < SETTLE_MS) return;
    // How far the picture is from where it should be: in step with the sound, adjusted by the
    // viewer's offset (a positive offset plays the sound later, so the picture runs ahead).
    const difference = this.origin + host + this.offsetMs - pictureDate;
    const magnitude = Math.abs(difference);
    if (Date.now() - this.lastReportAt >= REPORT_MS) {
      this.lastReportAt = Date.now();
      this.log(`Sync: picture ${describe(difference)}`);
    }
    if (!this.aligned) {
      this.retries = 0;
      this.move(difference, 'start');
      return;
    }
    if (this.checkingMove) {
      this.checkingMove = false;
      if (magnitude > MISS_TOLERANCE_MS && this.retries < QUICK_RETRIES) {
        this.retries += 1;
        this.move(difference, 'retry');
      } else {
        this.announce();
      }
      return;
    }
    this.driftCount = magnitude > DRIFT_THRESHOLD_MS ? this.driftCount + 1 : 0;
    if (this.driftCount < DRIFT_SAMPLES) return;
    const sinceMove = Date.now() - this.lastMoveAt;
    if (magnitude > JUMP_THRESHOLD_MS ? sinceMove >= JUMP_COOLDOWN_MS : sinceMove >= DRIFT_COOLDOWN_MS) {
      this.retries = 0;
      this.move(difference, 'drift');
    }
  }

  /** Moves the picture by `difference`: positive means it's behind, so it jumps forward. */
  private move(difference: number, reason: string): void {
    this.aligned = true;
    this.driftCount = 0;
    if (Math.abs(difference) < MISS_TOLERANCE_MS) {
      this.announce();
      return;
    }
    this.lastMoveAt = Date.now();
    this.settledAt = Date.now();
    this.checkingMove = true;
    this.log(`Moving the picture ${difference > 0 ? 'ahead' : 'back'} ${Math.round(Math.abs(difference))} ms to match the sound (${reason})`);
    this.movePicture(difference);
  }

  private announce(): void {
    if (this.announced) return;
    this.announced = true;
    this.onInSync();
  }

  private hostPosition(): number | null {
    const host = this.host;
    if (!host || !host.playing) return null;
    return host.positionMs + host.ageMs + (Date.now() - host.at);
  }

  private async poll(): Promise<void> {
    if (!this.url) return;
    if (this.origin === null && this.sessionID) {
      try {
        this.origin = (await this.link.hostTimeline(this.sessionID)).origin;
      } catch {
        // Asked again next time.
      }
    }
    try {
      const reply = await this.client.player.stateGet({ timeoutMs: 2_000 });
      if (reply.ok) this.record(reply.response.state.playback);
    } catch {
      // Keep the last report.
    }
  }

  private record(playback: { state: string; positionMs: number; positionAgeMs: number | null }): void {
    if (!this.url) return;
    const playing = playback.state === 'playing';
    if (playing && this.settledAt === null) this.settledAt = Date.now();
    if (!playing) this.settledAt = null;
    this.host = { positionMs: playback.positionMs, ageMs: playback.positionAgeMs ?? 0, playing, at: Date.now() };
  }
}

function describe(difference: number): string {
  return `${difference >= 0 ? 'behind' : 'ahead of'} the sound by ${Math.round(Math.abs(difference))} ms`;
}
