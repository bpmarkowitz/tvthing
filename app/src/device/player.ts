import Hls, { ErrorTypes, Events } from 'hls.js';
import { bufferedAhead } from './buffer';
import { makeLoader } from './loader';
import { errorMessage, type ExtensionLink } from './link';

/** How long each kind of trouble is given to clear up before the stream is reloaded. */
const RECOVERY_DELAY_MS = {
  network: 1_800,
  media: 5_000,
  pause: 4_000,
  autoplay: 2_500,
};
/** The backstop: with no new frames for this long, the stream is reloaded. */
const FROZEN_VIDEO_MS = 8_000;
/** A stall with at least this much buffered isn't waiting for data: the decoder is stuck. */
const STUCK_WITH_BUFFER_SECONDS = 2;
/** Right after a splice, the picture is watched closely so a stuck decoder is caught fast. */
const SPLICE_WATCH = { durationMs: 3_000, intervalMs: 100, stoppedMs: 350, minBufferSeconds: 1 };

/**
 * Full-screen HLS playback with automatic recovery.
 *
 * Ad-stitched streams hiccup where ads splice into the show: a gap in the buffer, a
 * timestamp jump, a short stall. hls.js rides through those itself (nudging past gaps,
 * resetting at discontinuities), and a full reload — black screen, re-buffer, audio
 * resync — is far more disruptive than the hiccup. So the player only reloads for
 * fatal errors or when the picture has truly stopped.
 *
 * One hiccup hls.js can't ride through: after splicing from an ad back into the show,
 * the Car Thing's decoder sometimes stops with plenty of video buffered. Seeking (or
 * resetting the decoder) while it's wedged crashes the Car Thing's browser, but a full
 * reload is safe, so the player reloads right away and lets the app cover the gap. Just
 * after each splice it watches frames closely, catching that in ~0.35 s rather than the
 * ~1 s hls.js takes to report a stall — before the computer's audio has drifted audibly.
 */
export class Player {
  private hls: Hls | null = null;
  private url: string | null = null;
  private recoveryTimer: number | undefined;
  private lastFrameAt = Date.now();
  private lastFrameCount = 0;
  private playing = false;
  private lastDiscontinuity: number | undefined;
  private spliceWatch: number | undefined;
  private startCount = 0;

  constructor(
    private readonly video: HTMLVideoElement,
    private readonly link: ExtensionLink,
    private readonly onStarted: () => void,
    /** The stream is about to reload mid-show; a chance to cover the gap. */
    private readonly onReloading: () => void,
    /** The stream couldn't load; the message explains why when TV Thing knows. */
    private readonly onFailed: (message: string) => void,
  ) {
    video.addEventListener('playing', () => {
      this.playing = true;
      this.lastFrameAt = Date.now();
      this.cancelRecovery();
      this.onStarted();
    });
    video.addEventListener('waiting', () => (this.playing = false));
    // Troubleshooting sync: hls.js sometimes jumps to catch up with the live edge.
    let seekFrom = 0;
    video.addEventListener('timeupdate', () => {
      if (!video.seeking) seekFrom = video.currentTime;
    });
    video.addEventListener('seeked', () => {
      if (Math.abs(video.currentTime - seekFrom) > 1) this.link.log(`Picture jumped from ${Math.round(seekFrom * 1000)} to ${Math.round(video.currentTime * 1000)} ms`);
    });
    video.addEventListener('pause', () => {
      this.playing = false;
      if (!this.url) return;
      // Try resuming in place first; reload only if that doesn't take.
      video.play().catch(() => {});
      this.scheduleRecovery('unexpected pause', RECOVERY_DELAY_MS.pause);
    });
    window.setInterval(() => this.checkForFrozenVideo(), 1_000);
  }

  /**
   * Where the picture is, in milliseconds on the stream's timeline. Bridgething's host player
   * measures the same playlist the same way, so the two are directly comparable.
   */
  get positionMs(): number {
    return this.video.currentTime * 1_000;
  }

  /** Program-date-time of the frame on screen, in Unix milliseconds, when the stream has it. */
  get programDate(): number | null {
    const time = this.hls?.playingDate?.getTime();
    return time !== undefined && Number.isFinite(time) ? time : null;
  }

  /** Increments on every (re)start of the stream. */
  get generation(): number {
    return this.startCount;
  }

  get isPlaying(): boolean {
    return this.playing && !this.video.paused && !this.video.ended;
  }

  play(url: string): void {
    this.url = url;
    this.start();
  }

  stop(): void {
    this.url = null;
    this.cancelRecovery();
    this.stopSpliceWatch();
    this.hls?.destroy();
    this.hls = null;
    this.playing = false;
    this.video.removeAttribute('src');
    this.video.load();
  }

  /**
   * Steps the picture back by up to a few seconds within what's already buffered, so the
   * sound can catch up with it. Skipped if that part of the stream isn't buffered any more.
   */
  holdBack(ms: number): void {
    const target = this.video.currentTime - Math.min(ms, 3_000) / 1_000;
    const { buffered } = this.video;
    for (let index = 0; index < buffered.length; index += 1) {
      if (target >= buffered.start(index) && target <= buffered.end(index)) {
        this.video.currentTime = target;
        return;
      }
    }
    this.link.log(`Couldn't hold the picture back ${Math.round(ms)} ms: not buffered`);
  }

  /** Nudges a paused video, e.g. after the user touches the screen. */
  resume(): void {
    if (this.url && this.video.paused) this.video.play().catch(() => {});
  }

  private start(): void {
    const url = this.url;
    if (!url) return;
    this.cancelRecovery();
    this.hls?.destroy();
    this.playing = false;
    this.startCount += 1;
    // Text tracks can't be removed from a <video> element, only disabled.
    for (const track of Array.from(this.video.textTracks)) track.mode = 'disabled';

    const hls = new Hls({
      loader: makeLoader(this.link),
      enableWorker: false,
      lowLatencyMode: false,
      maxBufferLength: 15,
      maxMaxBufferLength: 22,
      backBufferLength: 10,
      maxBufferSize: 8 * 1024 * 1024,
      startLevel: 0,
      manifestLoadingMaxRetry: 4,
      levelLoadingMaxRetry: 4,
      fragLoadingMaxRetry: 5,
      // The computer's player can't seek closer than about three segments to the live edge,
      // so the picture stays four back, leaving the sound room to line up with it.
      liveSyncDurationCount: 4,
      liveMaxLatencyDurationCount: 10,
      // Ad splices leave small holes and mismatched track lengths; jump and stretch over
      // them, and nudge sooner and harder when playback stalls, instead of stopping.
      maxBufferHole: 0.6,
      stretchShortVideoTrack: true,
      highBufferWatchdogPeriod: 1,
      nudgeOffset: 0.2,
      nudgeMaxRetry: 8,
      // No subtitles or closed captions: they're hard to read on a 4-inch screen, and the
      // tracks attach to the <video> element, so they'd linger across channel changes.
      enableWebVTT: false,
      enableIMSC1: false,
      enableCEA708Captions: false,
    });
    hls.subtitleDisplay = false;
    this.hls = hls;
    this.lastDiscontinuity = undefined;
    this.stopSpliceWatch();
    hls.on(Events.FRAG_CHANGED, (_event, { frag }) => {
      if (this.lastDiscontinuity !== undefined && frag.cc !== this.lastDiscontinuity) this.watchSplice();
      this.lastDiscontinuity = frag.cc;
    });

    hls.on(Events.MANIFEST_PARSED, () => {
      // hls.js orders levels by bitrate; the Car Thing is happiest with the lightest one.
      hls.currentLevel = 0;
      this.video.play().catch(() => this.scheduleRecovery('autoplay blocked', RECOVERY_DELAY_MS.autoplay));
    });
    hls.on(Events.ERROR, (_event, data) => {
      // Most non-fatal errors (holes, data stalls) are hls.js's to handle; the
      // frozen-video check below is the backstop if it can't.
      if (!data.fatal) {
        if (data.details === Hls.ErrorDetails.BUFFER_STALLED_ERROR) this.unstickIfDecoderStalled();
        return;
      }
      this.playing = false;
      if (data.type === ErrorTypes.MEDIA_ERROR) {
        hls.recoverMediaError();
        window.setTimeout(() => this.video.play().catch(() => {}), 300);
        this.scheduleRecovery('media error', RECOVERY_DELAY_MS.media);
      } else {
        this.link.log(`Stream error: ${data.details}`);
        const response = (data as { response?: { text?: unknown } }).response;
        const explained = typeof response?.text === 'string' ? errorMessage(response.text) : undefined;
        if (explained) this.onFailed(explained);
        this.scheduleRecovery(data.details, RECOVERY_DELAY_MS.network);
      }
    });

    hls.attachMedia(this.video);
    hls.loadSource(url);
    this.lastFrameAt = Date.now();
    this.lastFrameCount = this.frameCount();
  }

  /** A stall with video buffered means the decoder, not the network, is stuck. */
  private unstickIfDecoderStalled(): void {
    if (!this.hls || bufferedAhead(this.video) < STUCK_WITH_BUFFER_SECONDS) return;
    this.reloadMidShow('Playback stuck with video buffered; reloading the stream');
  }

  /** Watches the picture for a few seconds after a splice and reloads if it stops. */
  private watchSplice(): void {
    this.stopSpliceWatch();
    const until = Date.now() + SPLICE_WATCH.durationMs;
    let frames = this.frameCount();
    let progressAt = Date.now();
    this.spliceWatch = window.setInterval(() => {
      const now = Date.now();
      const current = this.frameCount();
      if (current > frames) {
        frames = current;
        progressAt = now;
      } else if (
        now - progressAt >= SPLICE_WATCH.stoppedMs &&
        !this.video.paused &&
        bufferedAhead(this.video) >= SPLICE_WATCH.minBufferSeconds
      ) {
        this.stopSpliceWatch();
        this.reloadMidShow('Picture stopped at a splice; reloading the stream');
        return;
      }
      if (now > until) this.stopSpliceWatch();
    }, SPLICE_WATCH.intervalMs);
  }

  private stopSpliceWatch(): void {
    window.clearInterval(this.spliceWatch);
    this.spliceWatch = undefined;
  }

  private reloadMidShow(reason: string): void {
    if (!this.url || this.recoveryTimer !== undefined) return;
    this.link.log(reason);
    this.onReloading();
    this.scheduleRecovery(reason, 0);
  }

  private scheduleRecovery(reason: string, delay: number): void {
    if (!this.url || this.recoveryTimer !== undefined) return;
    console.log('[TV Thing] recovery scheduled:', reason);
    this.recoveryTimer = window.setTimeout(() => {
      this.recoveryTimer = undefined;
      this.start();
    }, delay);
  }

  private cancelRecovery(): void {
    window.clearTimeout(this.recoveryTimer);
    this.recoveryTimer = undefined;
  }

  private checkForFrozenVideo(): void {
    const frames = this.frameCount();
    if (frames > this.lastFrameCount) {
      this.lastFrameCount = frames;
      this.lastFrameAt = Date.now();
    }
    if (this.url && Date.now() - this.lastFrameAt > FROZEN_VIDEO_MS) {
      this.lastFrameAt = Date.now();
      this.reloadMidShow('Picture froze; reloading the stream');
    }
  }

  private frameCount(): number {
    return this.video.getVideoPlaybackQuality?.().totalVideoFrames ?? 0;
  }
}
