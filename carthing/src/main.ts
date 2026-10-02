import { BridgethingClient } from '@bridgething/client';
import { bindInput } from './input';
import { MAC_ORIGIN, MacLink, VOLUME_STEP, type DeviceState, type TuneTarget } from './mac';
import { Player } from './player';
import { BridgethingTransport, BrowserTransport, type Transport } from './transport';
import { Guide } from './ui/guide';
import { Screen } from './ui/screen';
import { VolumeBar } from './ui/volume';

declare const __APP_VERSION__: string;

const STATE_POLL_MS = 1_000;
const SYNC_INTERVAL_MS = 500;
const RETRY_DELAY_MS = 2_500;
/** How long the Mac can go quiet before the viewer is told, if the picture has stopped. */
const DISCONNECT_GRACE_MS = 6_000;

/**
 * Coordinates the Car Thing side: follows the Mac's state, plays the current session,
 * reports playback position for audio sync, and turns button presses into requests.
 * All channel data and decisions live on the Mac.
 */
class App {
  private readonly link = new MacLink(makeTransport());
  private readonly screen = new Screen();
  private readonly guide = new Guide();
  private readonly volumeBar = new VolumeBar();
  /** Knob detents not yet sent to the Mac, while a volume request is in flight. */
  private pendingVolumeSteps = 0;
  private volumeInFlight = false;
  /** The level shown while requests are in flight, so the bar responds instantly. */
  private displayedVolume: number | null = null;
  private readonly player = new Player(
    this.screen.video,
    this.link,
    () => {
      this.screen.lockSignal();
      this.screen.revealAfterRecovery();
      this.screen.hideCard();
    },
    // Like a TV station's break: cut to black, and come back only once the picture is
    // clean. The Mac hears about it at once, so the sound cuts with the picture.
    () => {
      this.screen.blackout();
      this.reportPosition();
    },
  );
  private state: DeviceState | null = null;
  private sessionID: string | null = null;
  private connected = false;
  private failingSince: number | null = null;
  private lastFailure = '';
  private polling = false;
  private syncing = false;
  private syncAgain = false;
  private reportedVisible = true;

  start(): void {
    bindInput({
      preset: (slot) => this.pressPreset(slot),
      turn: (step) => this.turnKnob(step),
      press: () => this.pressKnob(),
      // The front button closes the guide; otherwise it's mute.
      back: () => (this.guide.isOpen ? this.guide.close() : this.toggleMute()),
      info: () => this.showInfo(),
      discovered: (key, mapped) => this.link.log(`${mapped ? 'Key' : 'Unmapped key'}: ${JSON.stringify(key)}`),
    });
    // Tapping the screen cycles the picture framing (fill, fit, zoom) for this channel.
    window.addEventListener('pointerdown', () => {
      this.player.resume();
      this.screen.toast(this.screen.framing.cycle());
    });
    window.addEventListener('error', (event) => this.link.log(`App error: ${event.message}`));
    // Leaving the app (home gesture, another app): tell the Mac to go quiet right away
    // instead of waiting for reports to stop.
    window.addEventListener('pagehide', () => this.sayGoodbye());
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') this.sayGoodbye();
    });

    this.screen.showCard('Connecting to your Mac…');
    this.link.log(`TV Thing ${__APP_VERSION__} started`);
    this.poll();
    window.setInterval(() => this.poll(), STATE_POLL_MS);
    window.setInterval(() => this.reportPosition(), SYNC_INTERVAL_MS);
    // Tell the Mac right away when the picture appears or disappears, so the sound follows it.
    window.setInterval(() => {
      if (this.screen.pictureVisible !== this.reportedVisible) this.reportPosition();
    }, 100);
  }

  // MARK: State

  private async poll(): Promise<void> {
    if (this.polling) return;
    this.polling = true;
    try {
      const state = await this.link.state();
      this.recordRecovery();
      this.apply(state);
      this.connected = true;
    } catch (error) {
      // Status checks share the USB bridge with video, so one can occasionally time out
      // while a segment downloads. Only interrupt the viewer if it persists with no picture.
      this.lastFailure = (error as Error).message;
      this.failingSince ??= Date.now();
      const persistent = Date.now() - this.failingSince >= DISCONNECT_GRACE_MS;
      if (!this.state || (persistent && !this.player.isPlaying)) {
        this.showDisconnected(this.lastFailure);
        this.connected = false;
      }
    } finally {
      this.polling = false;
    }
  }

  private apply(state: DeviceState): void {
    const previous = this.state;
    this.state = state;
    if (previous?.revision === state.revision && this.connected) return;

    if (state.display) this.screen.setDisplay(state.display);
    this.screen.setMuted(state.muted === true);
    this.guide.update(state.channels);
    const session = state.session;
    if (!session || state.phase === 'empty') {
      this.sessionID = null;
      this.player.stop();
      this.screen.showCard('No channels yet', 'Add channels in TV Thing on your Mac.');
      return;
    }

    if (session.id !== this.sessionID) {
      this.sessionID = session.id;
      this.screen.startTuning();
      if (state.channel) {
        this.screen.showChannel(state.channel);
        this.screen.framing.setChannel(state.channel.id);
      }
      this.player.play(MAC_ORIGIN + session.playlist);
    }

    if (state.phase === 'failed') {
      this.screen.showCard(state.channel?.name ?? 'Can’t play this channel', state.message ?? 'Retrying…');
    } else {
      // While tuning, the static and channel banner are feedback enough.
      this.screen.hideCard();
    }
  }

  /** Logs outages long enough to notice, once the Mac can be reached again. */
  private recordRecovery(): void {
    if (this.failingSince === null) return;
    const seconds = (Date.now() - this.failingSince) / 1_000;
    if (seconds >= 2) this.link.log(`Mac unreachable for ${seconds.toFixed(1)} s (${this.lastFailure})`);
    this.failingSince = null;
  }

  private showDisconnected(reason: string): void {
    this.screen.showCard('Can’t reach your Mac', `${reason}. Make sure TV Thing and Bridgething are running.`);
  }

  private sayGoodbye(): void {
    if (!this.sessionID) return;
    this.link
      .sync({ session: this.sessionID, position: this.player.position, playing: false, generation: this.player.generation, visible: false })
      .catch(() => {});
  }

  private async reportPosition(): Promise<void> {
    if (!this.sessionID || !this.connected) return;
    if (this.syncing) {
      this.syncAgain = true;
      return;
    }
    this.syncing = true;
    const visible = this.screen.pictureVisible;
    this.reportedVisible = visible;
    try {
      await this.link.sync({
        session: this.sessionID,
        position: this.player.position,
        playing: this.player.isPlaying,
        generation: this.player.generation,
        visible,
      });
    } catch {
      // The next poll reports connection problems.
    } finally {
      this.syncing = false;
      if (this.syncAgain) {
        this.syncAgain = false;
        this.reportPosition();
      }
    }
  }

  // MARK: Controls

  private pressPreset(slot: number): void {
    if (this.guide.isOpen) {
      // In the guide, a preset button saves the highlighted channel to that button.
      const channel = this.guide.highlighted;
      if (!channel) return;
      this.request(this.link.saveFavorite(slot, channel.id), `Saved to button ${slot + 1}`);
      return;
    }
    const assigned = this.state?.channels.some((channel) => channel.favorite === slot);
    if (!assigned) {
      this.screen.toast(`Button ${slot + 1} is empty. Save a channel from the guide.`);
      return;
    }
    this.tune({ favorite: slot });
  }

  private showInfo(): void {
    this.guide.close();
    if (this.state?.channel) this.screen.showChannel(this.state.channel, true);
  }

  private toggleMute(): void {
    // The corner badge is the only feedback; it appears and disappears with the state.
    this.link.mute().then(
      (state) => this.apply(state),
      (error: Error) => this.screen.toast(error.message),
    );
  }

  /** The knob is volume, as on the original Car Thing; with the guide open it browses. */
  private turnKnob(step: number): void {
    if (this.guide.isOpen) {
      this.guide.move(step);
      return;
    }
    if (!this.state) return;
    const current = this.displayedVolume ?? this.state.volume;
    this.displayedVolume = Math.min(1, Math.max(0, current + step * VOLUME_STEP));
    this.volumeBar.show(this.displayedVolume, this.state.muted && step < 0);
    this.pendingVolumeSteps += step;
    this.sendVolume();
  }

  /** Sends knob detents to the Mac, coalescing fast turns into one request. */
  private sendVolume(): void {
    if (this.volumeInFlight || this.pendingVolumeSteps === 0) return;
    const steps = this.pendingVolumeSteps;
    this.pendingVolumeSteps = 0;
    this.volumeInFlight = true;
    this.link.adjustVolume(steps).then(
      (state) => {
        this.volumeInFlight = false;
        this.apply(state);
        if (this.pendingVolumeSteps !== 0) {
          this.sendVolume();
        } else {
          this.displayedVolume = null;
          this.volumeBar.show(state.volume, state.muted);
        }
      },
      (error: Error) => {
        this.volumeInFlight = false;
        this.pendingVolumeSteps = 0;
        this.displayedVolume = null;
        this.screen.toast(error.message);
      },
    );
  }

  private pressKnob(): void {
    if (!this.guide.isOpen) {
      if (this.state?.channels.length) this.guide.open(this.state.channels, this.state.channel?.id);
      return;
    }
    const channel = this.guide.highlighted;
    this.guide.close();
    if (channel && channel.id !== this.state?.channel?.id) this.tune({ channel: channel.id });
  }

  private tune(target: TuneTarget): void {
    this.request(this.link.tune(target));
  }

  private request(pending: Promise<DeviceState>, confirmation?: string): void {
    pending.then(
      (state) => {
        this.apply(state);
        if (confirmation) this.screen.toast(confirmation);
      },
      (error: Error) => {
        this.screen.toast(error.message);
        window.setTimeout(() => this.poll(), RETRY_DELAY_MS);
      },
    );
  }
}

/** `?browser` runs the app in a desktop browser against `npm run dev`. */
function makeTransport(): Transport {
  if (new URLSearchParams(location.search).has('browser')) return new BrowserTransport();
  return new BridgethingTransport(new BridgethingClient({ url: `ws://${location.host}/` }));
}

new App().start();
