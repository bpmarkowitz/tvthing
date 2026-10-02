const SEGMENTS = 20;
const VISIBLE_MS = 2_000;

/** An old-TV volume display: a row of segments along the bottom of the screen. */
export class VolumeBar {
  private readonly root = document.getElementById('volume')!;
  private readonly segments: HTMLElement[] = [];
  private readonly level = this.root.querySelector('b')!;
  private hideTimer: number | undefined;

  constructor() {
    const track = this.root.querySelector('div')!;
    for (let index = 0; index < SEGMENTS; index += 1) {
      const segment = document.createElement('i');
      track.append(segment);
      this.segments.push(segment);
    }
  }

  show(volume: number, muted: boolean): void {
    const lit = Math.round(Math.min(Math.max(volume, 0), 1) * SEGMENTS);
    this.segments.forEach((segment, index) => segment.classList.toggle('on', index < lit));
    this.level.textContent = muted ? 'MUTE' : String(lit);
    this.root.classList.toggle('muted', muted);
    this.root.classList.add('show');
    window.clearTimeout(this.hideTimer);
    this.hideTimer = window.setTimeout(() => this.root.classList.remove('show'), VISIBLE_MS);
  }
}
