# Adding a stream provider

A provider teaches TV Thing about a new kind of source, such as a streaming service with its own URLs or tokens. Nothing outside the provider needs to know how it works.

## 1. Write the provider

Providers live in the extension, in `app/extension/engine/`:

```ts
import type { SourceReference } from '../../src/shared/library';
import type { Provider } from './providers';
import type { Upstream } from './relay';

export const exampleProvider: Provider = {
  id: 'example',

  /**
   * Produce a playable HLS playlist. `refresh` is true after upstream rejected a request
   * (401/403), so drop any cached session or token.
   */
  async resolve(reference: SourceReference, refresh: boolean): Promise<Upstream> {
    const token = await session(refresh);
    return {
      entryURL: new URL(`https://watch.example.com/live/${reference.value}/master.m3u8`),
      // Runs for every playlist, key, and segment request made for this stream.
      prepare(url) {
        const prepared = new URL(url);
        prepared.searchParams.set('token', token);
        return prepared;
      },
    };
  },
};
```

Guidelines:
- Store only what's needed to resolve later in `reference.value`: an ID, not a signed URL that expires.
- Keep session state (tokens and so on) in the provider's module, and refresh it when `refresh` is true.
- The extension's permissions already allow network access to any host.

## 2. Register it

Add it to `providers` in `providers.ts`:

```ts
export const providers: Provider[] = [exampleProvider, hlsProvider];
```

## 3. Add channels that use it

Channels name their provider in their source, so a [channel pack](channel-packs.md) can add them:

```json
{ "name": "Example Live", "source": { "provider": "example", "value": "channel-123" } }
```

## 4. Test it

Add tests in `app/tests/` and run `make test`. For a live check, run `make dev` and tune the channel in the browser.

That's all. Compatibility probing, conversion, relaying, sync, and the Car Thing UI work automatically for the new source.
