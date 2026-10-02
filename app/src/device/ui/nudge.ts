/** The audio sync display shown while the knob is in nudge mode. */
export class NudgeDisplay {
  private readonly root = document.getElementById('nudge')!;
  private readonly value = this.root.querySelector('b')!;
  private readonly marker = this.root.querySelector('i')!;

  get isOpen(): boolean {
    return this.root.classList.contains('show');
  }

  show(offsetMs: number): void {
    this.value.textContent =
      offsetMs === 0 ? 'In sync' : `${(Math.abs(offsetMs) / 1_000).toFixed(2)} s ${offsetMs > 0 ? 'later' : 'earlier'}`;
    // The track spans ±1 s; larger offsets pin to the end.
    const fraction = Math.max(-1, Math.min(1, offsetMs / 1_000));
    this.marker.style.left = `${50 + fraction * 50}%`;
    this.root.classList.add('show');
  }

  close(): void {
    this.root.classList.remove('show');
  }
}
