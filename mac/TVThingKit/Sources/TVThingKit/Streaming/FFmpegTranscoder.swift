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

    private let executable: URL
    private let input: URL
    private let log: DiagnosticsLog
    private var process: Process?
    private var directory: URL?
    private var errorTail = ErrorTail()

    /// On-demand sources are read in real time and looped, so they play like a channel.
    private let loopsOnDemandInput: Bool

    init(executable: URL, input: URL, onDemand: Bool, log: DiagnosticsLog) {
        self.loopsOnDemandInput = onDemand
        self.executable = executable
        self.input = input
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

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(input: input, output: directory, onDemand: loopsOnDemandInput)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.record(text) }
        }
        try process.run()
        self.process = process
        self.directory = directory
        await log.record("Started FFmpeg conversion", source: .mac)
        return try await waitForPlaylist(in: directory, process: process)
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    /// Removes output left behind if the app previously quit without cleaning up.
    static func removeStaleOutput() {
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

    static func arguments(input: URL, output: URL, onDemand: Bool) -> [String] {
        // Live input arrives in real time by itself; a finished video would otherwise be
        // converted as fast as possible and outrun the rolling playlist.
        let pacing = onDemand ? ["-re", "-stream_loop", "-1"] : []
        return [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "4",
        ] + pacing + [
            "-i", input.absoluteString,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-vf", "scale=w=800:h=480:force_original_aspect_ratio=decrease:force_divisible_by=2",
            "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
            "-profile:v", "main", "-level:v", "3.1", "-pix_fmt", "yuv420p",
            "-b:v", "700k", "-maxrate", "900k", "-bufsize", "1400k",
            "-g", "48", "-keyint_min", "48", "-sc_threshold", "0",
            "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-ar", "48000",
            "-f", "hls", "-hls_time", "2", "-hls_list_size", "8", "-hls_delete_threshold", "4",
            "-hls_flags", "delete_segments+program_date_time+independent_segments+omit_endlist",
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
