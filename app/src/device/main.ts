import { BridgethingClient } from '@bridgething/client';
import { API_VERSION, EXTENSION_ORIGIN } from '../shared/api';
import type { Channel } from '../shared/library';
import { browserClient } from './browser';
import { bindInput } from './input';
import { ExtensionLink } from './link';
import { Player } from './player';
import { Sound } from './sound';
import { Store } from './store';
import { BridgethingTransport, BrowserTransport } from './transport';
import { Guide } from './ui/guide';
import { NudgeDisplay } from './ui/nudge';
import { Screen } from './ui/screen';
import { VolumeBar } from './ui/volume';

declare const __APP_VERSION__: string;

const SYNC_INTERVAL_MS = 500;
const HEALTH_RETRY_MS = 3_000;
/** How much one knob detent changes the volume: twenty steps, like an old TV. */
const VOLUME_STEP = 0.05;
/** Volume reports this soon after the knob set it are the computer's rounded echo. */
const VOLUME_ECHO_MS = 2_000;
/** How much one knob detent shifts the sound in nudge mode. */
const NUDGE_STEP_MS = 50;
const NUDGE_LIMIT_MS = 5_000;
/** Nudge mode closes itself after this long without a turn. */
const NUDGE_IDLE_MS = 8_000;
/** Saving the offset waits until the knob stops. */
const NUDGE_SAVE_DELAY_MS = 800;

/**
 * The knob has three modes, cycled by pressing it: volume (the default), the channel guide,
 * and nudge, which shifts the sound earlier or later against the picture. In the guide, a
 * press on a different channel tunes it; on the channel already playing, it moves on to nudge.
 */
type KnobMode = 'volume' | 'guide' | 'nudge';

/**
 * The Car Thing side of TV Thing. Picture plays here; sound plays on the computer through
 * Bridgething's host player, kept in line with the picture. TV Thing's extension on the
 * computer relays (and if needed converts) each stream for both.
 */
class App {
  private readonly browser = new URLSearchParams(location.search).has('browser');
  private readonly client: BridgethingClient = this.browser ? browserClient() : new BridgethingClient({ url: `ws://${location.host}/` });
  private readonly link = new ExtensionLink(this.browser ? new BrowserTransport() : new BridgethingTransport(this.client));
  private readonly store = new Store(this.client, (message) => this.link.log(message));
  private readonly sound = new Sound(
    this.client,
    this.link,
    (message) => this.link.log(message),
    (ms) => this.player.shift(ms),
  );
  private readonly screen = new Screen();
  private readonly guide = new Guide();
  private readonly nudge = new NudgeDisplay();
  private readonly volumeBar = new VolumeBar();
  private readonly player = new Player(
    this.screen.video,
    this.link,
    () => this.pictureStarted(),
    // Like a TV station's break: cut to black, and come back only once the picture is
    // clean. The sound keeps playing, and the picture rejoins it when it comes back.
    () => {
      this.screen.blackout();
      this.sound.realign();
    },
    (message) => this.screen.showCard(this.store.current?.name ?? 'Can’t play this channel', message),
  );
  private mode: KnobMode = 'volume';
  private tuned: { channel: Channel; playlist: string; session: string } | null = null;
  private tuneGeneration = 0;
  private volume: { level: number; muted: boolean } | null = null;
  private nudgeTimer: number | undefined;
  private volumeSetAt = 0;
  private saveTimer: number | undefined;

  async start(): Promise<void> {
    bindInput({
      preset: (slot) => this.pressPreset(slot),
      turn: (step) => this.turnKnob(step),
      press: () => this.pressKnob(),
      // The front button backs out of the guide or nudge; otherwise it's mute.
      back: () => (this.mode === 'volume' ? this.toggleMute() : this.setMode('volume')),
      info: () => this.showInfo(),
      discovered: (key, mapped) => this.link.log(`${mapped ? 'Key' : 'Unmapped key'}: ${JSON.stringify(key)}`),
    });
    // Tapping the screen cycles the picture framing (fill, fit, zoom) for this channel.
    window.addEventListener('pointerdown', () => {
      this.player.resume();
      this.screen.toast(this.screen.framing.cycle());
    });
    window.addEventListener('error', (event) => this.link.log(`App error: ${event.message}`));
    // Leaving the app (home gesture, another app) silences the computer right away.
    window.addEventListener('pagehide', () => this.sound.stop());
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') this.sound.stop();
      else if (this.tuned) this.retune();
    });
    this.client.audio.onVolumeChanged(({ level, muted }) => {
      // The computer rounds the volume to its own steps and reports that back. Keep the level
      // the knob asked for unless the volume really changed (e.g. from the computer's keys),
      // or turning down can get stuck re-rounding to the same step.
      const close = this.volume !== null && Math.abs(level - this.volume.level) < VOLUME_STEP;
      if (close && Date.now() - this.volumeSetAt < VOLUME_ECHO_MS) {
        this.volume = { level: this.volume!.level, muted };
      } else {
        this.volume = { level, muted };
      }
      this.screen.setMuted(muted);
    });

    this.screen.showCard('Starting TV Thing…');
    await this.store.load();
    this.store.onChange(() => this.libraryChanged());
    this.screen.setDisplay(this.store.prefs);
    this.sound.setOffset(this.store.prefs.audioOffsetMs);
    window.setInterval(() => this.sound.follow(this.player.programDate, this.player.isPlaying), SYNC_INTERVAL_MS);
    await this.waitForExtension();
    this.link.log(`TV Thing ${__APP_VERSION__} started`);
    this.tuneCurrent();
  }

  /** The extension starts with Bridgething; it may still be coming up when the app opens. */
  private async waitForExtension(): Promise<void> {
    for (;;) {
      try {
        const health = await this.link.health();
        if (health.api >= API_VERSION) return;
        this.screen.showCard('Update TV Thing', 'The TV Thing helper on your computer is out of date. Reinstall TV Thing in Bridgething.');
      } catch (error) {
        this.screen.showCard('Can’t reach your computer', `${(error as Error).message}. Make sure Bridgething is running and TV Thing is installed.`);
      }
      await new Promise((resolve) => window.setTimeout(resolve, HEALTH_RETRY_MS));
    }
  }

  // Tuning

  private tuneCurrent(): void {
    const channel = this.store.current;
    if (!channel) {
      this.tuned = null;
      this.player.stop();
      this.sound.stop();
      this.screen.showCard('No channels yet', 'Add channels in TV Thing’s settings in Bridgething.');
      return;
    }
    this.tune(channel);
  }

  private async tune(channel: Channel): Promise<void> {
    const generation = ++this.tuneGeneration;
    this.store.setCurrent(channel.id);
    this.screen.hideCard();
    this.screen.startTuning();
    const info = this.store.info(channel.id);
    if (info) this.screen.showChannel(info);
    this.screen.framing.setChannel(channel.id);
    this.sound.stop();
    try {
      const session = await this.link.createSession({ source: channel.source, playback: channel.playback });
      if (generation !== this.tuneGeneration) return;
      this.tuned = { channel, playlist: EXTENSION_ORIGIN + session.playlist, session: session.id };
      this.player.play(this.tuned.playlist);
    } catch (error) {
      if (generation !== this.tuneGeneration) return;
      this.player.stop();
      this.screen.showCard(channel.name, (error as Error).message);
    }
  }

  /** Starts the current channel over with a fresh stream, e.g. after returning to the app. */
  private retune(): void {
    if (this.tuned) this.tune(this.tuned.channel);
  }

  /** The picture is moving: (re)start the sound from the same playlist, then line it up. */
  private pictureStarted(): void {
    this.screen.lockSignal();
    this.screen.revealAfterRecovery();
    this.screen.hideCard();
    if (this.tuned && !this.sound.isActive) this.sound.play(this.tuned.playlist, this.tuned.session);
  }

  private libraryChanged(): void {
    this.screen.setDisplay(this.store.prefs);
    this.sound.setOffset(this.store.prefs.audioOffsetMs);
    this.guide.update(this.store.channels);
    const current = this.store.current;
    if (!current) {
      this.tuneCurrent();
      return;
    }
    // Changing what the current channel plays (or removing it) needs a fresh stream.
    const tuned = this.tuned?.channel;
    if (!tuned || tuned.id !== current.id || tuned.source.value !== current.source.value || tuned.source.provider !== current.source.provider || tuned.playback !== current.playback) {
      this.tune(current);
    } else {
      this.tuned = { ...this.tuned!, channel: current };
    }
  }

  // Controls

  private setMode(mode: KnobMode): void {
    this.mode = mode;
    if (mode !== 'guide') this.guide.close();
    if (mode !== 'nudge') {
      this.nudge.close();
      window.clearTimeout(this.nudgeTimer);
    }
    if (mode === 'guide') this.guide.open(this.store.channels, this.store.current?.id, () => this.mode === 'guide' && this.setMode('volume'));
    if (mode === 'nudge') this.showNudge();
  }

  private pressKnob(): void {
    switch (this.mode) {
      case 'volume':
        if (this.store.library.channels.length) this.setMode('guide');
        else this.setMode('nudge');
        return;
      case 'guide': {
        const highlighted = this.guide.highlighted;
        const current = this.store.current;
        if (highlighted && highlighted.id !== current?.id) {
          this.setMode('volume');
          const channel = this.store.library.channels.find((candidate) => candidate.id === highlighted.id);
          if (channel) this.tune(channel);
        } else {
          this.setMode('nudge');
        }
        return;
      }
      case 'nudge':
        this.setMode('volume');
    }
  }

  private turnKnob(step: number): void {
    switch (this.mode) {
      case 'guide':
        this.guide.move(step);
        return;
      case 'nudge':
        this.shiftSound(step * NUDGE_STEP_MS);
        return;
      case 'volume':
        this.changeVolume(step);
    }
  }

  private showNudge(): void {
    this.nudge.show(this.store.prefs.audioOffsetMs);
    window.clearTimeout(this.nudgeTimer);
    this.nudgeTimer = window.setTimeout(() => this.mode === 'nudge' && this.setMode('volume'), NUDGE_IDLE_MS);
  }

  private shiftSound(deltaMs: number): void {
    const prefs = this.store.prefs;
    const offset = Math.max(-NUDGE_LIMIT_MS, Math.min(NUDGE_LIMIT_MS, prefs.audioOffsetMs + deltaMs));
    this.store.prefs = { ...prefs, audioOffsetMs: offset };
    this.sound.setOffset(offset);
    this.showNudge();
    window.clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => this.store.savePrefs(this.store.prefs), NUDGE_SAVE_DELAY_MS);
  }

  /** The knob sets the computer's volume. Turning it up also unmutes, like a TV. */
  private changeVolume(step: number): void {
    const audio = this.client.audio;
    if (!this.volume) {
      (step > 0 ? audio.volumeUp() : audio.volumeDown()).catch(() => {});
      return;
    }
    const wasMuted = this.volume.muted;
    const level = Math.min(1, Math.max(0, Math.round(this.volume.level / VOLUME_STEP + step) * VOLUME_STEP));
    const muted = wasMuted && step < 0;
    this.volume = { level, muted };
    this.volumeBar.show(level, muted);
    this.screen.setMuted(muted);
    this.volumeSetAt = Date.now();
    audio.setVolume({ level }).catch(() => {});
    if (wasMuted && !muted) audio.setMute({ muted: false }).catch(() => {});
  }

  private toggleMute(): void {
    const muted = !(this.volume?.muted ?? false);
    if (this.volume) this.volume = { ...this.volume, muted };
    this.screen.setMuted(muted);
    this.client.audio.setMute({ muted }).catch((error: Error) => this.screen.toast(error.message));
  }

  private pressPreset(slot: number): void {
    if (this.mode === 'guide') {
      // In the guide, a preset button saves the highlighted channel to that button.
      const channel = this.guide.highlighted;
      if (!channel) return;
      this.store.saveFavorite(slot, channel.id).then(() => this.screen.toast(`Saved to button ${slot + 1}`));
      return;
    }
    const channel = this.store.favorite(slot);
    if (!channel) {
      this.screen.toast(`Button ${slot + 1} is empty. Save a channel from the guide.`);
      return;
    }
    if (channel.id !== this.store.current?.id) this.tune(channel);
  }

  private showInfo(): void {
    this.setMode('volume');
    const info = this.store.current && this.store.info(this.store.current.id);
    if (info) this.screen.showChannel(info, true);
  }
}

new App().start().catch((error: Error) => console.error('[TV Thing]', error));
