/** How the picture fits the Car Thing's wide screen. */
type Framing = 'fill' | 'fit' | 'zoom';

const ORDER: Framing[] = ['fill', 'fit', 'zoom'];
const LABELS: Record<Framing, string> = { fill: 'Fill', fit: 'Fit', zoom: 'Zoom' };
const STORAGE_PREFIX = 'framing:';

/**
 * Tap-to-cycle picture framing, remembered per channel on the Car Thing:
 * - fill: covers the screen, trimming the edges (the default)
 * - fit: shows the whole picture, with black bars
 * - zoom: crops further, removing the side bars of 4:3 shows inside a 16:9 picture
 */
export class FramingControl {
  private channelID: string | null = null;
  private current: Framing = 'fill';

  constructor(private readonly frame: HTMLElement) {}

  /** Applies the framing remembered for a channel. */
  setChannel(id: string): void {
    this.channelID = id;
    this.apply(this.load(id));
  }

  /** Moves to the next framing and returns its name for display. */
  cycle(): string {
    const next = ORDER[(ORDER.indexOf(this.current) + 1) % ORDER.length];
    this.apply(next);
    if (this.channelID) this.save(this.channelID, next);
    return LABELS[next];
  }

  private apply(framing: Framing): void {
    this.current = framing;
    for (const option of ORDER) this.frame.classList.toggle(option, option === framing);
  }

  private load(id: string): Framing {
    try {
      const stored = localStorage.getItem(STORAGE_PREFIX + id);
      return ORDER.includes(stored as Framing) ? (stored as Framing) : 'fill';
    } catch {
      return 'fill';
    }
  }

  private save(id: string, framing: Framing): void {
    try {
      if (framing === 'fill') localStorage.removeItem(STORAGE_PREFIX + id);
      else localStorage.setItem(STORAGE_PREFIX + id, framing);
    } catch {
      // Storage can be unavailable; framing then just isn't remembered.
    }
  }
}
