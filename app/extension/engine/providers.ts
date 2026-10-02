// Stream providers turn a channel's source reference into a playable HLS URL. Adding a new kind
// of source means adding a provider here; the rest of TV Thing only deals in references.

import type { SourceReference } from '../../src/shared/library';
import type { Upstream } from './relay.ts';

export interface Provider {
  id: string;
  /** A playable playlist for a reference. `refresh` follows an upstream auth failure. */
  resolve(reference: SourceReference, refresh: boolean): Promise<Upstream>;
}

/** Any publicly reachable HLS playlist URL. */
export const hlsProvider: Provider = {
  id: 'hls',
  async resolve(reference) {
    return { entryURL: new URL(reference.value) };
  },
};

export const providers: Provider[] = [hlsProvider];

export function provider(id: string): Provider {
  const found = providers.find((candidate) => candidate.id === id);
  if (!found) throw new Error(`This channel uses “${id}”, which this version of TV Thing doesn't support.`);
  return found;
}
