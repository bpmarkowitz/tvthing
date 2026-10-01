import type { ChannelInfo, DisplayOptions } from '../mac';
import { TuningEffect } from './tuning';

const BUG_DURATION_MS = 2_600;
/** After a mid-show reload, how long the picture plays unseen before fading back in. */
const RECOVERY_REVEAL_MS = 2_000;
const INFO_DURATION_MS = 5_000;
const TOAST_DURATION_MS = 1_800;

function element<T extends HTMLElement>(id: string): T {
  const found = document.getElementById(id);
  if (!found) throw new Error(`Missing #${id}`);
  return found as T;
}

/** On-screen overlays drawn above the video. The screen is otherwise just picture. */
export class Screen {
  readonly video = element<HTMLVideoElement>('video');
  private readonly tuning = new TuningEffect(element<HTMLCanvasElement>('static'), this.video);
  private readonly bug = element('bug');
  private readonly card = element('card');
  private readonly toastElement = element('toast');
  private readonly mutedBadge = element('muted');
  private bugTimer: number | undefined;
  private revealTimer: number | undefined;
  private blackedOut = false;
  private toastTimer: number | undefined;

  /**
   * The channel number and name in the corner, like a TV's on-screen display.
   * `lingering` keeps it up longer, for when the viewer asked to see it.
   */
  showChannel(channel: ChannelInfo, lingering = false): void {
    this.bug.querySelector('b')!.textContent = String(channel.number);
    this.bug.querySelector('span')!.textContent = channel.name;
    this.bug.classList.add('show');
    window.clearTimeout(this.bugTimer);
    this.bugTimer = window.setTimeout(() => this.bug.classList.remove('show'), lingering ? INFO_DURATION_MS : BUG_DURATION_MS);
  }

  /** Analog static while a new channel loads; `lockSignal()` rolls the picture in. */
  startTuning(): void {
    // A channel change replaces any recovery blackout with the tuning effect.
    window.clearTimeout(this.revealTimer);
    this.blackedOut = false;
    this.video.classList.remove('blackout');
    this.tuning.start();
  }

  lockSignal(): void {
    this.tuning.lock();
  }

  /** False while tuning static or a recovery blackout hides the picture. */
  get pictureVisible(): boolean {
    return !this.blackedOut && !this.video.classList.contains('searching');
  }

  /** Cuts the picture to black at once, while the stream recovers behind it. */
  blackout(): void {
    window.clearTimeout(this.revealTimer);
    this.blackedOut = true;
    this.video.classList.add('blackout');
  }

  /** Once playback resumes after a blackout, fades back in after it has run cleanly. */
  revealAfterRecovery(): void {
    if (!this.blackedOut) return;
    window.clearTimeout(this.revealTimer);
    this.revealTimer = window.setTimeout(() => {
      this.blackedOut = false;
      this.video.classList.remove('blackout');
    }, RECOVERY_REVEAL_MS);
  }

  /** Persistent picture styling chosen on the Mac. */
  setDisplay(options: DisplayOptions): void {
    document.body.classList.toggle('crt', options.scanlines);
  }

  /** A small speaker-off badge while the Mac's audio is muted. */
  setMuted(muted: boolean): void {
    this.mutedBadge.classList.toggle('show', muted);
  }

  /** A centered message for states with no picture: connecting, empty lineup, errors. */
  showCard(title: string, detail = ''): void {
    this.card.querySelector('strong')!.textContent = title;
    this.card.querySelector('p')!.textContent = detail;
    this.card.classList.add('show');
  }

  hideCard(): void {
    this.card.classList.remove('show');
  }

  toast(message: string): void {
    this.toastElement.textContent = message;
    this.toastElement.classList.add('show');
    window.clearTimeout(this.toastTimer);
    this.toastTimer = window.setTimeout(() => this.toastElement.classList.remove('show'), TOAST_DURATION_MS);
  }
}
