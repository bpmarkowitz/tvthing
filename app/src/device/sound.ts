import type { BridgethingClient } from '@bridgething/client';

/** Seeking costs a moment of silence, so small differences are left alone. */
const DRIFT_THRESHOLD_MS = 250;
/** Consecutive out-of-sync checks before re-aligning, so one jittery report is ignored. */
const DRIFT_SAMPLES = 3;
/** Automatic re-aligns are at most this frequent. */
const DRIFT_COOLDOWN_MS = 20_000;
/** A difference this large (e.g. the host player rebuffered) is fixed sooner. */
const JUMP_THRESHOLD_MS = 2_000;
const JUMP_COOLDOWN_MS = 5_000;
/** The host player reports itself playing a little before its position settles. */
const SETTLE_MS = 1_200;
const POLL_MS = 1_000;

interface HostReport {
  positionMs: number;
  ageMs: number;
  playing: boolean;
  at: number;
}

/**
 * The sound, played on the computer by Bridgething's host player from the same playlist as
 * the picture. Both players measure position from the start of that playlist, so lining them
 * up is a seek to where the picture is, plus the viewer's own offset.
 */
export class Sound {
  private url: string | null = null;
  private host: HostReport | null = null;
  private playingSince: number | null = null;
  private aligned = false;
  private lastAlignAt = 0;
  private driftCount = 0;
  private offsetMs = 0;

  constructor(private readonly client: BridgethingClient, private readonly log: (message: string) => void) {
    client.player.onSnapshot((reply) => this.record(reply.state.playback));
    window.setInterval(() => this.poll(), POLL_MS);
  }

  get isActive(): boolean {
    return this.url !== null;
  }

  /** Starts the sound from the top of the playlist; `follow` then lines it up with the picture. */
  play(url: string): void {
    this.url = url;
    this.host = null;
    this.playingSince = null;
    this.aligned = false;
    this.driftCount = 0;
    this.client.player.play({ uri: url, context: null }).catch((error: Error) => this.log(`Host player wouldn't play: ${error.message}`));
  }

  stop(): void {
    if (this.url === null) return;
    this.url = null;
    this.host = null;
    this.client.player.pause().catch(() => {});
  }

  /** Positive plays the sound later than the picture. Applied at once. */
  setOffset(ms: number): void {
    if (ms === this.offsetMs) return;
    this.offsetMs = ms;
    this.aligned = false;
  }

  /** Call regularly with where the picture is; re-aligns the sound when it has drifted. */
  follow(pictureMs: number, picturePlaying: boolean): void {
    const host = this.hostPosition();
    if (!this.url || !picturePlaying || host === null || this.playingSince === null) return;
    if (Date.now() - this.playingSince < SETTLE_MS) return;
    const target = pictureMs - this.offsetMs;
    const difference = host - target;
    const magnitude = Math.abs(difference);
    const sinceAlign = Date.now() - this.lastAlignAt;
    if (!this.aligned) {
      this.align(target, difference, 'start');
      return;
    }
    this.driftCount = magnitude > DRIFT_THRESHOLD_MS ? this.driftCount + 1 : 0;
    if (this.driftCount < DRIFT_SAMPLES) return;
    if (magnitude > JUMP_THRESHOLD_MS ? sinceAlign >= JUMP_COOLDOWN_MS : sinceAlign >= DRIFT_COOLDOWN_MS) this.align(target, difference, 'drift');
  }

  private align(target: number, difference: number, reason: string): void {
    this.aligned = true;
    this.lastAlignAt = Date.now();
    this.driftCount = 0;
    // The seek takes a moment to land; reports until then would read as more drift.
    this.playingSince = Date.now();
    if (Math.abs(difference) < 40) return;
    this.log(`Aligned sound (${reason}, was ${difference > 0 ? 'ahead' : 'behind'} by ${Math.round(Math.abs(difference))} ms)`);
    this.client.player.seekTo({ positionMs: Math.max(0, Math.round(target)) }).catch(() => {});
  }

  private hostPosition(): number | null {
    const host = this.host;
    if (!host || !host.playing) return null;
    return host.positionMs + host.ageMs + (Date.now() - host.at);
  }

  private async poll(): Promise<void> {
    if (!this.url) return;
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
    if (playing && this.playingSince === null) this.playingSince = Date.now();
    if (!playing) this.playingSince = null;
    this.host = { positionMs: playback.positionMs, ageMs: playback.positionAgeMs ?? 0, playing, at: Date.now() };
  }
}
