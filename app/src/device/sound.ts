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
  private lastReportAt = 0;
  private seekLeadMs = loadSeekLead();
  /** Set after a seek, until where it landed has been checked. */
  private checkingSeek = false;
  private retries = 0;

  constructor(private readonly client: BridgethingClient, private readonly log: (message: string) => void) {
    client.player.onSnapshot((reply) => this.record(reply.state.playback, 'push'));
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
    this.checkingSeek = false;
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
    if (Date.now() - this.lastReportAt >= REPORT_MS) {
      this.lastReportAt = Date.now();
      const age = this.host ? Date.now() - this.host.at : 0;
      this.log(`Sync: sound ${difference >= 0 ? 'ahead' : 'behind'} by ${Math.round(Math.abs(difference))} ms (picture ${Math.round(pictureMs)} ms, report ${age} ms old, reported age ${this.host?.ageMs ?? 0} ms)`);
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
      this.log(`Seek landed ${Math.round(Math.abs(difference))} ms ${difference >= 0 ? 'ahead' : 'behind'}; aiming ${this.seekLeadMs} ms ahead from now on`);
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
    // The seek takes a moment to land; reports until then would read as more drift.
    this.playingSince = Date.now();
    if (Math.abs(difference) < 40) return;
    this.checkingSeek = true;
    const aim = target + this.seekLeadMs;
    this.log(`Aligned sound (${reason}, was ${difference > 0 ? 'ahead' : 'behind'} by ${Math.round(Math.abs(difference))} ms): seek to ${Math.round(aim)} ms`);
    this.client.player.seekTo({ positionMs: Math.max(0, Math.round(aim)) }).catch(() => {});
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
      if (reply.ok) this.record(reply.response.state.playback, 'poll');
    } catch {
      // Keep the last report.
    }
  }

  private record(playback: { state: string; positionMs: number; positionAgeMs: number | null }, source: string): void {
    if (!this.url) return;
    const playing = playback.state === 'playing';
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
