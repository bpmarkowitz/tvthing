import type { BridgethingClient } from '@bridgething/client';
import { DEFAULT_PREFS, DOC, type Library, mergeChannels, parseLibrary, parsePrefs, type Prefs, setFavorite } from '../shared/library';
import { STARTER_CHANNELS } from '../shared/starter';

/** A channel as the Car Thing shows it. */
export interface ChannelInfo {
  id: string;
  /** 1-based position in the lineup. */
  number: number;
  name: string;
  /** Car Thing button (0–3) this channel is saved to. */
  favorite?: number;
}

/**
 * The lineup and preferences, kept in Bridgething's doc storage for this app. The settings
 * page on the computer edits the same docs, and changes there arrive here live.
 */
export class Store {
  library: Library = { channels: [], favorites: [null, null, null, null] };
  prefs: Prefs = { ...DEFAULT_PREFS };
  currentID: string | null = null;
  private listeners: (() => void)[] = [];

  constructor(private readonly client: BridgethingClient, private readonly log: (message: string) => void) {}

  async load(): Promise<void> {
    this.client.doc.onChanged(({ key, value }) => this.apply(key, value));
    const [library, prefs, current] = await Promise.all([this.read(DOC.library), this.read(DOC.prefs), this.read(DOC.current)]);
    this.prefs = parsePrefs(prefs);
    this.currentID = current;
    if (library === null) {
      // First run: start with the free channels, so the buttons work straight away.
      this.library = mergeChannels(this.library, STARTER_CHANNELS).library;
      await this.write(DOC.library, JSON.stringify(this.library));
    } else {
      this.library = parseLibrary(library);
    }
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  get channels(): ChannelInfo[] {
    return this.library.channels.map((channel, index) => {
      const slot = this.library.favorites.indexOf(channel.id);
      return { id: channel.id, number: index + 1, name: channel.name, favorite: slot >= 0 ? slot : undefined };
    });
  }

  /** The channel on air: the last one watched, else the first. */
  get current() {
    return this.library.channels.find((channel) => channel.id === this.currentID) ?? this.library.channels[0];
  }

  info(id: string): ChannelInfo | undefined {
    return this.channels.find((channel) => channel.id === id);
  }

  channelAt(step: number) {
    const channels = this.library.channels;
    if (!channels.length) return undefined;
    const index = channels.findIndex((channel) => channel.id === this.current?.id);
    return channels[(((index + step) % channels.length) + channels.length) % channels.length];
  }

  favorite(slot: number) {
    const id = this.library.favorites[slot];
    return id ? this.library.channels.find((channel) => channel.id === id) : undefined;
  }

  setCurrent(id: string): void {
    this.currentID = id;
    this.write(DOC.current, id);
  }

  async saveFavorite(slot: number, id: string): Promise<void> {
    this.library = setFavorite(this.library, id, slot);
    this.notify();
    await this.write(DOC.library, JSON.stringify(this.library));
  }

  savePrefs(prefs: Prefs): void {
    this.prefs = prefs;
    this.write(DOC.prefs, JSON.stringify(prefs));
  }

  private apply(key: string, value: string | null): void {
    if (key === DOC.library) this.library = parseLibrary(value);
    else if (key === DOC.prefs) this.prefs = parsePrefs(value);
    else return;
    this.notify();
  }

  private notify(): void {
    for (const listener of this.listeners) listener();
  }

  private async read(key: string): Promise<string | null> {
    const reply = await this.client.doc.get({ key });
    return reply.ok ? reply.response.value : null;
  }

  private async write(key: string, value: string): Promise<void> {
    try {
      const reply = await this.client.doc.set({ key, value });
      if (!reply.ok) this.log(`Couldn't save ${key}: ${JSON.stringify(reply)}`);
    } catch (error) {
      this.log(`Couldn't save ${key}: ${(error as Error).message}`);
    }
  }
}
