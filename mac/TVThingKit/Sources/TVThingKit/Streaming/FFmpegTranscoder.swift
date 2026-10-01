import Foundation

/// Finds an FFmpeg executable. Apps launched from Finder don't inherit the shell's
/// `PATH`, so common package-manager locations are checked explicitly.
public enum FFmpegLocator {
    public static let searchPaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg"
    ]

    public static func locate(customPath: String? = nil) -> URL? {
        var candidates: [String] = []
        if let customPath, !customPath.isEmpty { candidates.append((customPath as NSString).expandingTildeInPath) }
        candidates += searchPaths
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/ffmpeg" }
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

/// Re-encodes a live stream into Car Thing–friendly HLS: H.264 main profile at up to
/// 800×480, AAC stereo, two-second segments, and program-date-time stamps for audio sync.
actor FFmpegTranscoder {
    enum TranscoderError: LocalizedError {
        case exited(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .exited(let detail): "FFmpeg couldn't convert this stream. \(detail)"
            case .timedOut: "FFmpeg took too long to start this stream."
            }
        }
    }

    static let workRoot = FileManager.default.temporaryDirectory.appending(path: "TVThing-Transcodes", directoryHint: .isDirectory)

    /// What to convert, and how.
    struct Source: Sendable {
        var url: URL
        /// A finished video rather than a live stream: paced to real time and looped.
        var onDemand: Bool
        /// The source variant to convert (FFmpeg exposes each as a program), or `nil` for the first.
        var program: Int?
    }

    /// FFmpeg finishing this soon after starting means the input is broken, not that the
    /// video ended, so it isn't restarted.
    private static let minimumLoopInterval: TimeInterval = 3

    private let executable: URL
    private let source: Source
    private let log: DiagnosticsLog
    private var process: Process?
    private var directory: URL?
    private var startedAt = Date.distantPast
    private var errorTail = ErrorTail()

    init(executable: URL, source: Source, log: DiagnosticsLog) {
        self.executable = executable
        self.source = source
        self.log = log
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Starts FFmpeg if needed and returns the output playlist once it has segments.
    func playlist() async throws -> URL {
        if let process, process.isRunning, let directory {
            return try await waitForPlaylist(in: directory, process: process)
        }
        stop()
        let directory = Self.workRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = try launch(into: directory, continuing: false)
        self.directory = directory
        await log.record("Started FFmpeg conversion", source: .mac)
        return try await waitForPlaylist(in: directory, process: process)
    }

    private func launch(into directory: URL, continuing: Bool) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(source: source, output: directory, continuing: continuing)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.record(text) }
        }
        process.terminationHandler = { [weak self] ended in
            Task { await self?.processEnded(ended) }
        }
        try process.run()
        self.process = process
        startedAt = .now
        return process
    }

    /// Loops on-demand sources: when the video ends, FFmpeg restarts and appends to the
    /// same playlist, so players see one continuous channel. FFmpeg's own `-stream_loop`
    /// isn't used because it retries instantly forever if its input fails, which, if
    /// TV Thing ever died mid-conversion, would flood the local port.
    private func processEnded(_ ended: Process) async {
        guard ended === process, let directory, source.onDemand, ended.terminationStatus == 0 else { return }
        guard Date.now.timeIntervalSince(startedAt) >= Self.minimumLoopInterval else {
            await log.record("FFmpeg ended too soon to loop; stopping conversion", source: .mac)
            return
        }
        do {
            _ = try launch(into: directory, continuing: true)
            await log.record("Looping on-demand video", source: .mac)
        } catch {
            await log.record("Couldn't loop: \(error.localizedDescription)", source: .mac)
        }
    }

    func stop() {
        let process = self.process
        self.process = nil
        if let process, process.isRunning { process.terminate() }
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    /// Stops conversions and removes output left behind if the app previously crashed or
    /// was force-quit. Leftover FFmpeg processes are recognized by their output path, and
    /// only orphans (now owned by launchd) are stopped, never another running instance's.
    static func removeStaleOutput() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-P", "1", "-f", workRoot.path]
        try? pkill.run()
        pkill.waitUntilExit()
        try? FileManager.default.removeItem(at: workRoot)
    }

    private func waitForPlaylist(in directory: URL, process: Process) async throws -> URL {
        let playlist = directory.appending(path: "index.m3u8")
        let deadline = Date.now.addingTimeInterval(20)
        while Date.now < deadline {
            if let data = try? Data(contentsOf: playlist), String(decoding: data, as: UTF8.self).contains("#EXTINF") {
                return playlist
            }
            guard process.isRunning else { throw TranscoderError.exited(errorTail.summary) }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw TranscoderError.timedOut
    }

    private func record(_ text: String) async {
        errorTail.append(text)
        for line in text.split(separator: "\n") where !line.isEmpty {
            await log.record("FFmpeg: \(line)", source: .mac)
        }
    }

    static func arguments(source: Source, output: URL, continuing: Bool) -> [String] {
        // Live input arrives in real time by itself; a finished video would otherwise be
        // converted as fast as possible and outrun the rolling playlist. A short initial
        // burst fills the buffer (not again when looping, or playback would run ahead of
        // real time), and catch-up keeps download delays from adding up.
        let burst = continuing ? [] : ["-readrate_initial_burst", "6"]
        let pacing = source.onDemand ? ["-readrate", "1"] + burst + ["-readrate_catchup", "1.5"] : []
        let streams = source.program.map { "0:p:\($0)" } ?? "0"
        // Continuing a loop appends to the existing playlist, marked as a discontinuity.
        let flags = "delete_segments+program_date_time+independent_segments+omit_endlist" + (continuing ? "+append_list+discont_start" : "")
        return [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "4",
        ] + pacing + [
            "-i", source.url.absoluteString,
            "-map", "\(streams):v:0", "-map", "\(streams):a:0?",
            // Deinterlace broadcast (1080i) video; progressive frames pass through untouched.
            "-vf", "yadif=deint=interlaced,scale=w=800:h=480:force_original_aspect_ratio=decrease:force_divisible_by=2",
            // 60 fps is needless work for the Car Thing's decoder; slower sources keep their rate.
            "-fpsmax", "30",
            "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
            "-profile:v", "main", "-level:v", "3.1", "-pix_fmt", "yuv420p",
            "-b:v", "700k", "-maxrate", "900k", "-bufsize", "1400k",
            "-g", "48", "-keyint_min", "48", "-sc_threshold", "0",
            "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-ar", "48000",
            "-f", "hls", "-hls_time", "2", "-hls_list_size", "8", "-hls_delete_threshold", "4",
            "-hls_flags", flags,
            "-hls_segment_filename", output.appending(path: "segment-%06d.ts").path,
            output.appending(path: "index.m3u8").path
        ]
    }
}

/// Keeps the last few lines FFmpeg printed, for error messages.
private struct ErrorTail {
    private var lines: [String] = []

    mutating func append(_ text: String) {
        lines += text.split(separator: "\n").map(String.init)
        lines = Array(lines.suffix(3))
    }

    var summary: String { lines.joined(separator: " ") }
}
