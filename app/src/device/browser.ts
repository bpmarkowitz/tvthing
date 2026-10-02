import type { BridgethingClient } from '@bridgething/client';

/**
 * For development in a desktop browser (`npm run dev`, then `?browser`): stands in for the
 * parts of Bridgething the app uses. Docs live in localStorage and the host player only
 * pretends, so the picture and controls can be tested without a Car Thing.
 */
export function browserClient(): BridgethingClient {
  const docListeners: ((change: { key: string; value: string | null }) => void)[] = [];
  const volumeListeners: ((change: { level: number; muted: boolean }) => void)[] = [];
  let volume = { level: 0.5, muted: false };
  const setVolume = (next: Partial<typeof volume>) => {
    volume = { ...volume, ...next };
    for (const listener of volumeListeners) listener(volume);
  };
  const ok = <T>(response: T) => Promise.resolve({ ok: true as const, response });
  const playback = { state: 'stopped', positionMs: 0, positionAgeMs: 0 };
  let startedAt = 0;

  window.addEventListener('storage', (event) => {
    if (event.key?.startsWith('doc:')) for (const listener of docListeners) listener({ key: event.key.slice(4), value: event.newValue });
  });

  const client = {
    doc: {
      onChanged: (listener: (typeof docListeners)[number]) => docListeners.push(listener),
      get: ({ key }: { key: string }) => ok({ key, value: localStorage.getItem(`doc:${key}`) }),
      set: ({ key, value }: { key: string; value: string }) => {
        localStorage.setItem(`doc:${key}`, value);
        return ok({});
      },
    },
    audio: {
      onVolumeChanged: (listener: (typeof volumeListeners)[number]) => {
        volumeListeners.push(listener);
        window.setTimeout(() => listener(volume));
      },
      volumeUp: async () => setVolume({ level: Math.min(1, volume.level + 0.05) }),
      volumeDown: async () => setVolume({ level: Math.max(0, volume.level - 0.05) }),
      setVolume: async ({ level }: { level: number }) => setVolume({ level }),
      setMute: async ({ muted }: { muted: boolean }) => setVolume({ muted }),
    },
    player: {
      onSnapshot: () => () => {},
      play: async ({ uri }: { uri: string }) => {
        console.log('[TV Thing] host player would play', uri);
        startedAt = Date.now();
        playback.state = 'playing';
      },
      pause: async () => {
        playback.state = 'paused';
      },
      seekTo: async ({ positionMs }: { positionMs: number }) => {
        console.log('[TV Thing] host player would seek to', positionMs);
        startedAt = Date.now() - positionMs;
      },
      stateGet: () => {
        playback.positionMs = playback.state === 'playing' ? Date.now() - startedAt : playback.positionMs;
        return ok({ state: { playback } });
      },
    },
  };
  return client as unknown as BridgethingClient;
}
