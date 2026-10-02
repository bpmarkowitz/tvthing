import type { BridgethingClient } from '@bridgething/client';
import type { ExtensionLink } from './link';

/** Seeking costs a moment of silence, so small differences are left alone. */
const DRIFT_THRESHOLD_MS = 250;
/** Consecutive out-of-sync checks before re-aligning, so one jittery report is ignored. */
const DRIFT_SAMPLES = 3;
/** Automatic re-aligns are at most this frequent. */
const DRIFT_COOLDOWN_MS = 20_000;
/** A difference this large (e.g. the host player rebuffered) is fixed sooner. */
const JUMP_THRESHOLD_MS = 2_000;
const JUMP_COOLDOWN_MS = 5_000;
/** After starting or seeking, the host player's reports take a moment to settle. */
const SETTLE_MS = 2_000;
/**
 * A seek takes a moment to land, and the sound resumes from the requested point only then,
 * so seeks aim ahead by this much. It's learned from where each seek lands (and remembered).
 */
const INITIAL_SEEK_LEAD_MS = 300;
const MAXIMUM_SEEK_LEAD_MS = 1_500;
const SEEK_LEAD_KEY = 'sound:seekLead';
/** After a seek, a miss larger than this is corrected straight away (a few times at most). */
const MISS_TOLERANCE_MS = 100;
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
 * the picture, and kept in line with it.
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
  private playingSince: number | null = null;
  private aligned = false;
  private lastAlignAt = 0;
  private driftCount = 0;
  private offsetMs = 0;
  private lastReportAt = 0;
  private seekLeadMs = loadSeekLead();
  /** The position last sought to: Bridgething echoes it straight back, which isn't a real report. */
  private soughtTo: { positionMs: number; at: number } | null = null;
  /** Set after a seek, until where it landed has been checked. */
  private checkingSeek = false;
  private retries = 0;

  constructor(
    private readonly client: BridgethingClient,
    private readonly link: ExtensionLink,
    private readonly log: (message: string) => void,
  ) {
    client.player.onSnapshot((reply) => this.record(reply.state.playback, 'push'));
    window.setInterval(() => this.poll(), POLL_MS);
  }

  get isActive(): boolean {
    return this.url !== null;
  }

  /** Starts the sound from the playlist; `follow` then lines it up with the picture. */
  async play(url: string, sessionID: string): Promise<void> {
    this.url = url;
    this.sessionID = sessionID;
    this.origin = null;
    this.host = null;
    this.playingSince = null;
    this.aligned = false;
    this.checkingSeek = false;
    this.soughtTo = null;
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

  /** Positive plays the sound later than the picture. Applied at once. */
  setOffset(ms: number): void {
    if (ms === this.offsetMs) return;
    this.offsetMs = ms;
    this.aligned = false;
  }

  /**
   * Call regularly with the program-date-time of the frame on screen (null if unknown);
   * re-aligns the sound when it has drifted.
   */
  follow(pictureDate: number | null, picturePlaying: boolean): void {
    const host = this.hostPosition();
    if (!this.url || !picturePlaying || pictureDate === null || this.origin === null || host === null || this.playingSince === null) return;
    if (Date.now() - this.playingSince < SETTLE_MS) return;
    const target = pictureDate - this.offsetMs - this.origin;
    const difference = host - target;
    const magnitude = Math.abs(difference);
    const sinceAlign = Date.now() - this.lastAlignAt;
    if (Date.now() - this.lastReportAt >= REPORT_MS) {
      this.lastReportAt = Date.now();
      this.log(`Sync: sound ${describe(difference)} (host at ${Math.round(host)} ms, picture at ${Math.round(target)} ms on the host's timeline)`);
    }
    if (!this.aligned) {
      this.retries = 0;
      this.align(target, difference, 'start');
      return;
    }
    if (this.checkingSeek) {
      // Learn how far ahead to aim from where the seek landed, and fix a clear miss now.
      this.checkingSeek = false;
      this.seekLeadMs = Math.max(0, Math.min(MAXIMUM_SEEK_LEAD_MS, Math.round(this.seekLeadMs - difference)));
      saveSeekLead(this.seekLeadMs);
      this.log(`Seek landed ${describe(difference)}; aiming ${this.seekLeadMs} ms ahead from now on`);
      if (magnitude > MISS_TOLERANCE_MS && this.retries < QUICK_RETRIES) {
        this.retries += 1;
        this.align(target, difference, 'retry');
      }
      return;
    }
    this.driftCount = magnitude > DRIFT_THRESHOLD_MS ? this.driftCount + 1 : 0;
    if (this.driftCount < DRIFT_SAMPLES) return;
    if (magnitude > JUMP_THRESHOLD_MS ? sinceAlign >= JUMP_COOLDOWN_MS : sinceAlign >= DRIFT_COOLDOWN_MS) {
      this.retries = 0;
      this.align(target, difference, 'drift');
    }
  }

  private align(target: number, difference: number, reason: string): void {
    this.aligned = true;
    this.lastAlignAt = Date.now();
    this.driftCount = 0;
    if (Math.abs(difference) < 40) return;
    // Reports until the seek lands would read as more drift.
    this.playingSince = Date.now();
    this.checkingSeek = true;
    const aim = Math.max(0, Math.round(target + this.seekLeadMs));
    this.soughtTo = { positionMs: aim, at: Date.now() };
    this.log(`Aligning sound (${reason}, ${describe(difference)}): seek to ${aim} ms`);
    this.client.player.seekTo({ positionMs: aim }).catch(() => {});
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
      if (reply.ok) this.record(reply.response.state.playback, 'poll');
    } catch {
      // Keep the last report.
    }
  }

  private record(playback: { state: string; positionMs: number; positionAgeMs: number | null }, source: string): void {
    if (!this.url) return;
    const playing = playback.state === 'playing';
    // Right after a seek, Bridgething reports the requested position before the player gets there.
    const echo = this.soughtTo && playback.positionMs === this.soughtTo.positionMs && Date.now() - this.soughtTo.at < 3_000;
    if (echo) return;
    // Troubleshooting: note reports that don't continue from the previous one.
    const expected = this.hostPosition();
    const reported = playback.positionMs + (playback.positionAgeMs ?? 0);
    if (expected === null || !playing || Math.abs(reported - expected) > 300) {
      this.log(`Host ${source}: ${playback.state} at ${playback.positionMs} ms, age ${playback.positionAgeMs ?? 'none'}${expected === null ? '' : `, expected ${Math.round(expected)}`}`);
    }
    if (playing && this.playingSince === null) this.playingSince = Date.now();
    if (!playing) this.playingSince = null;
    this.host = { positionMs: playback.positionMs, ageMs: playback.positionAgeMs ?? 0, playing, at: Date.now() };
  }
}

function describe(difference: number): string {
  return `${difference >= 0 ? 'ahead' : 'behind'} by ${Math.round(Math.abs(difference))} ms`;
}

function loadSeekLead(): number {
  try {
    const stored = Number(localStorage.getItem(SEEK_LEAD_KEY));
    return Number.isFinite(stored) && stored > 0 ? Math.min(stored, MAXIMUM_SEEK_LEAD_MS) : INITIAL_SEEK_LEAD_MS;
  } catch {
    return INITIAL_SEEK_LEAD_MS;
  }
}

function saveSeekLead(ms: number): void {
  try {
    localStorage.setItem(SEEK_LEAD_KEY, String(ms));
  } catch {
    // Not remembered; it's learned again next time.
  }
}
