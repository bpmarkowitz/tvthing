import type { ChannelInfo } from '../mac';

const VISIBLE_ROWS = 7;
const AUTO_CLOSE_MS = 6_000;

/**
 * The channel guide, browsed with the knob. It shows a window of rows around the
 * highlighted channel and closes itself after a few idle seconds.
 */
export class Guide {
  private readonly root = document.getElementById('guide')!;
  private readonly list = this.root.querySelector('ol')!;
  private channels: ChannelInfo[] = [];
  private index = 0;
  private closeTimer: number | undefined;

  get isOpen(): boolean {
    return this.root.classList.contains('show');
  }

  get highlighted(): ChannelInfo | undefined {
    return this.channels[this.index];
  }

  open(channels: ChannelInfo[], currentID: string | undefined): void {
    if (channels.length === 0) return;
    this.channels = channels;
    this.index = Math.max(0, channels.findIndex((channel) => channel.id === currentID));
    this.root.classList.add('show');
    this.render();
  }

  move(step: number): void {
    const count = this.channels.length;
    if (count === 0) return;
    this.index = (((this.index + step) % count) + count) % count;
    this.render();
  }

  /** Refreshes names and favorites while open, keeping the highlight on the same channel. */
  update(channels: ChannelInfo[]): void {
    if (!this.isOpen) return;
    const highlightedID = this.highlighted?.id;
    this.channels = channels;
    this.index = Math.max(0, channels.findIndex((channel) => channel.id === highlightedID));
    if (channels.length === 0) this.close();
    else this.render();
  }

  close(): void {
    window.clearTimeout(this.closeTimer);
    this.root.classList.remove('show');
  }

  private render(): void {
    window.clearTimeout(this.closeTimer);
    this.closeTimer = window.setTimeout(() => this.close(), AUTO_CLOSE_MS);

    const count = this.channels.length;
    const rows = Math.min(VISIBLE_ROWS, count);
    const first = count <= VISIBLE_ROWS ? 0 : this.index - Math.floor(VISIBLE_ROWS / 2);
    this.list.replaceChildren();
    for (let offset = 0; offset < rows; offset += 1) {
      const position = (((first + offset) % count) + count) % count;
      const channel = this.channels[position];
      const row = document.createElement('li');
      if (position === this.index) row.className = 'selected';
      const number = document.createElement('b');
      number.textContent = String(channel.number);
      const name = document.createElement('span');
      name.textContent = channel.name;
      row.append(number, name);
      if (channel.favorite !== undefined) {
        const badge = document.createElement('i');
        badge.textContent = String(channel.favorite + 1);
        row.append(badge);
      }
      this.list.append(row);
    }
  }
}
