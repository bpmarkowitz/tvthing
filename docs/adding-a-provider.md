# Adding a stream provider

A provider teaches TV Thing about a new kind of source, such as a streaming service with its own URLs or tokens. Nothing outside the provider needs to know how it works.

## 1. Implement `StreamProvider`

```swift
public struct ExampleProvider: StreamProvider {
    public let id: ProviderID = "example"
    public let displayName = "Example TV"

    /// Offline check: does this input look like ours? Used to route what the user typed.
    public func accepts(_ input: String) -> Bool {
        URL(string: input)?.host == "watch.example.com"
    }

    /// Validate input (network allowed) and return a stable reference plus a suggested name.
    public func candidate(for input: String) async throws -> SourceCandidate {
        let channelID = …
        return SourceCandidate(reference: .init(provider: id, value: channelID), suggestedName: "…")
    }

    /// Produce a playable HLS playlist. `refresh` is true after upstream rejected a
    /// request (401/403), so drop any cached session or token.
    public func resolve(_ reference: SourceReference, refresh: Bool) async throws -> ResolvedStream {
        let token = try await session(refresh: refresh)
        return ResolvedStream(playlistURL: …) { request in
            // Runs for every playlist, key, and segment request made for this stream.
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    public func summary(of reference: SourceReference) -> String { "Example TV · \(reference.value)" }
}
```

Guidelines:
- Store only what's needed to resolve later in `reference.value`: an ID, not a signed URL that expires.
- Make `accepts` specific. The generic `HLSProvider` catches any leftover URL, so it must stay last.
- If the provider keeps state (sessions, tokens), make it an `actor`, with the protocol's synchronous members marked `nonisolated`.

## 2. Register it

Add it to `ProviderRegistry.standard` in `StreamProvider.swift`, before `HLSProvider`:

```swift
ProviderRegistry(providers: [ExampleProvider(), HLSProvider(http: http)])
```

## 3. Test it

Add routing and parsing tests next to `ProviderTests` in `StreamingTests.swift`. For a live check, add a case to `EngineIntegrationTests` and run `make integration`.

That's all. Compatibility probing, conversion, relaying, audio sync, channel packs, and the Car Thing UI work automatically for the new source.
