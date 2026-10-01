const FRAME_MS = 50;
/** Rows the dark "vertical hold" bar travels per frame, on the 96-row canvas. */
const ROLL_SPEED = 3;
const ROLL_BAR_ROWS = 22;
/** Picture visible but unsteady under thinning static, hiding the stream's rough start. */
const SETTLE_MS = 2_500;
const LOCK_MS = 450;
/** Even instant channel changes show some static, or the effect doesn't read. */
const MIN_SEARCH_MS = 800;

/**
 * An analog-TV channel change, in three phases:
 * 1. searching: static with a rolling hold bar while the new stream loads;
 * 2. settling: the picture jitters under thinning static (streams often look washed
 *    out for their first few seconds, and this hides it);
 * 3. locking: a final roll and flash as the picture snaps clean.
 *
 * Noise is drawn on a small canvas and scaled up with CSS, which keeps it cheap
 * enough for the Car Thing.
 */
export class TuningEffect {
  private readonly context: CanvasRenderingContext2D | null;
  private readonly image: ImageData | null;
  private readonly pixels: Uint32Array | null;
  private frameTimer: number | undefined;
  private lockTimer: number | undefined;
  private finishTimer: number | undefined;
  private rollOffset = 0;
  private tuning = false;
  private startedAt = 0;

  constructor(
    private readonly canvas: HTMLCanvasElement,
    private readonly video: HTMLVideoElement,
  ) {
    this.context = canvas.getContext('2d');
    this.image = this.context?.createImageData(canvas.width, canvas.height) ?? null;
    this.pixels = this.image ? new Uint32Array(this.image.data.buffer) : null;
  }

  /** Static until `lock()` is called. */
  start(): void {
    window.clearTimeout(this.lockTimer);
    window.clearTimeout(this.finishTimer);
    this.tuning = true;
    this.startedAt = Date.now();
    this.rollOffset = Math.floor(Math.random() * this.canvas.height);
    this.video.classList.remove('settling', 'locking');
    this.video.classList.add('searching');
    this.canvas.classList.remove('settling', 'locking');
    this.canvas.classList.add('on');
    this.drawFrame();
    window.clearInterval(this.frameTimer);
    this.frameTimer = window.setInterval(() => this.drawFrame(), FRAME_MS);
  }

  /** The signal arrived: let the picture settle in under the static, then lock. */
  lock(): void {
    if (!this.tuning) return;
    const remaining = MIN_SEARCH_MS - (Date.now() - this.startedAt);
    if (remaining > 0) {
      window.clearTimeout(this.lockTimer);
      this.lockTimer = window.setTimeout(() => this.lock(), remaining);
      return;
    }
    this.tuning = false;
    this.video.classList.remove('searching');
    this.restartAnimation(this.video, 'settling');
    this.restartAnimation(this.canvas, 'settling');
    this.lockTimer = window.setTimeout(() => this.snap(), SETTLE_MS);
  }

  private snap(): void {
    this.video.classList.remove('settling');
    this.canvas.classList.remove('settling');
    this.restartAnimation(this.video, 'locking');
    this.restartAnimation(this.canvas, 'locking');
    this.finishTimer = window.setTimeout(() => {
      window.clearInterval(this.frameTimer);
      this.canvas.classList.remove('on', 'locking');
      this.video.classList.remove('locking');
    }, LOCK_MS);
  }

  private restartAnimation(element: HTMLElement, className: string): void {
    element.classList.remove(className);
    void element.offsetWidth;
    element.classList.add(className);
  }

  private drawFrame(): void {
    const { context, image, pixels } = this;
    if (!context || !image || !pixels) return;
    const width = this.canvas.width;
    const height = this.canvas.height;
    this.rollOffset = (this.rollOffset + ROLL_SPEED) % height;

    for (let row = 0; row < height; row += 1) {
      // Distance below the top of the rolling bar, wrapping around the screen.
      const intoBar = (row - this.rollOffset + height) % height;
      let gain = intoBar < ROLL_BAR_ROWS ? 0.35 + (0.4 * intoBar) / ROLL_BAR_ROWS : 1;
      // The bright edge where the bar ends, and the odd burst of interference.
      if (intoBar === ROLL_BAR_ROWS || Math.random() < 0.012) gain = 1.7;

      const start = row * width;
      for (let column = 0; column < width; column += 1) {
        const noise = Math.random() < 0.06 ? 255 : Math.random() * 200;
        const value = Math.min(255, noise * gain) | 0;
        // Little-endian RGBA: alpha in the top byte.
        pixels[start + column] = 0xff000000 | (value << 16) | (value << 8) | value;
      }
    }
    context.putImageData(image, 0, 0);
  }
}
