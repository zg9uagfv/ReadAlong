import AVFoundation
import Foundation

struct TimedTranscriptWord: Sendable {
    let text: String
    let start: Double
    let end: Double
}
struct WhisperTranscription: Sendable {
    let text: String
    let words: [TimedTranscriptWord]
}

@MainActor
final class LocalWhisperConfiguration: ObservableObject {
    @Published var localWhisperEnabled: Bool { didSet { save() } }
    @Published var localWhisperModel: String { didSet { save() } }
    @Published var localWhisperModelDirectory: String { didSet { save() } }
    @Published var localWhisperPythonPath: String { didSet { save() } }

    init() {
        let defaults = UserDefaults.standard
        localWhisperEnabled = defaults.bool(forKey: "localWhisperEnabled")
        localWhisperModel = defaults.string(forKey: "localWhisperModel") ?? "mlx-community/whisper-large-v3-turbo"
        localWhisperModelDirectory = defaults.string(forKey: "localWhisperModelDirectory") ?? ""
        let savedRuntime = defaults.string(forKey: "localWhisperPythonPath") ?? ""
        localWhisperPythonPath = FileManager.default.isExecutableFile(atPath: savedRuntime)
            ? savedRuntime
            : Self.detectLocalWhisperRuntime()
        if localWhisperPythonPath != savedRuntime {
            defaults.set(localWhisperPythonPath, forKey: "localWhisperPythonPath")
        }
    }

    private func save() {
        UserDefaults.standard.set(localWhisperEnabled, forKey: "localWhisperEnabled")
        UserDefaults.standard.set(localWhisperModel, forKey: "localWhisperModel")
        UserDefaults.standard.set(localWhisperModelDirectory, forKey: "localWhisperModelDirectory")
        UserDefaults.standard.set(localWhisperPythonPath, forKey: "localWhisperPythonPath")
    }

    private static func detectLocalWhisperRuntime() -> String {
        let candidates = [
            NSHomeDirectory() + "/.local/share/readalong-whisper/bin/python",
            NSHomeDirectory() + "/Library/Application Support/ReadAlong/whisper/bin/python",
            // Keep existing local runtimes usable after upgrading from EnglishReader.
            NSHomeDirectory() + "/.local/share/englishreader-whisper/bin/python",
            NSHomeDirectory() + "/Library/Application Support/EnglishReader/whisper/bin/python",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
}

@MainActor
enum LocalWhisperService {
    private final class CancellableProcess: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var cancelled = false

        func start() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            try process.run()
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    static func transcribe(
        url: URL,
        configuration: LocalWhisperConfiguration,
        onChunk: @MainActor (WhisperTranscription, Int, Int) -> Void
    ) async throws {
        let runtimePath = configuration.localWhisperPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runtimePath.isEmpty else {
            throw LocalWhisperError.runtimeNotConfigured
        }
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
            throw LocalWhisperError.runtimeUnavailable
        }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadAlong-Whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw LocalWhisperError.invalidDuration
        }
        let chunkLength = 60.0
        let chunkCount = Int(ceil(duration / chunkLength))
        guard let workerURL = Bundle.main.url(forResource: "whisper-worker", withExtension: "py") else {
            throw LocalWhisperError.workerMissing
        }

        var arguments = [
            workerURL.path, url.path, outputDirectory.path,
            "--model", configuration.localWhisperModel,
            "--chunk-seconds", String(chunkLength),
            "--chunk-count", String(chunkCount)
        ]
        let modelDirectory = configuration.localWhisperModelDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelDirectory.isEmpty {
            arguments += ["--model-dir", modelDirectory]
        }
        let workerArguments = arguments
        let completionURL = outputDirectory.appendingPathComponent("process-complete")
        async let processResult = run(
            executable: runtimePath,
            arguments: workerArguments,
            completionURL: completionURL
        )

        for chunkIndex in 0..<chunkCount {
            try Task.checkCancellation()
            let start = Double(chunkIndex) * chunkLength
            let jsonURL = outputDirectory
                .appendingPathComponent(String(format: "chunk_%04d.json", chunkIndex))
            while !FileManager.default.fileExists(atPath: jsonURL.path) {
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: completionURL.path) {
                    let result = try await processResult
                    guard result.status == 0 else {
                        throw LocalWhisperError.processFailed(summary(of: result.output))
                    }
                    throw LocalWhisperError.outputMissing
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
            let transcription = try parse(data: Data(contentsOf: jsonURL))
            let shifted = WhisperTranscription(
                text: transcription.text,
                words: transcription.words.map {
                    TimedTranscriptWord(text: $0.text, start: start + $0.start, end: start + $0.end)
                }
            )
            onChunk(shifted, chunkIndex + 1, chunkCount)
        }
        let result = try await processResult
        guard result.status == 0 else {
            throw LocalWhisperError.processFailed(summary(of: result.output))
        }
    }

    private static func parse(data: Data) throws -> WhisperTranscription {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["text"] is String || json["segments"] is [[String: Any]] else {
            throw LocalWhisperError.outputInvalid
        }
        let segments = json["segments"] as? [[String: Any]] ?? []
        let words = segments.flatMap { segment -> [TimedTranscriptWord] in
            (segment["words"] as? [[String: Any]] ?? []).compactMap { word in
                guard let text = (word["word"] as? String) ?? (word["text"] as? String),
                      let start = number(word["start"]),
                      let end = number(word["end"]) else { return nil }
                return TimedTranscriptWord(text: text, start: start, end: end)
            }
        }
        let segmentText = segments.compactMap { $0["text"] as? String }.joined(separator: " ")
        let text = (json["text"] as? String) ?? segmentText
        return WhisperTranscription(text: text, words: words)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func summary(of output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
        if let error = lines.last(where: { $0.localizedCaseInsensitiveContains("error:") }) {
            return String(error)
        }
        return String(lines.last ?? "未知错误")
    }

    private static func run(
        executable: String,
        arguments: [String],
        completionURL: URL
    ) async throws -> (status: Int32, output: String) {
        try Task.checkCancellation()
        let cancellable = CancellableProcess()
        let process = cancellable.process
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { try? Data().write(to: completionURL, options: .atomic) }
                    do {
                        let logURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("ReadAlong-Whisper-log-\(UUID().uuidString)")
                        FileManager.default.createFile(atPath: logURL.path, contents: nil)
                        let log = try FileHandle(forWritingTo: logURL)
                        defer {
                            try? log.close()
                            try? FileManager.default.removeItem(at: logURL)
                        }
                        process.executableURL = URL(fileURLWithPath: executable)
                        process.arguments = arguments
                        // The model downloader cannot use an inherited SOCKS proxy
                        // without socksio, so the subprocess uses a direct connection.
                        var environment = ProcessInfo.processInfo.environment
                        for key in ["ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"] {
                            environment.removeValue(forKey: key)
                        }
                        process.environment = environment
                        process.standardOutput = log
                        process.standardError = log
                        try cancellable.start()
                        process.waitUntilExit()
                        try log.synchronize()
                        let output = String(data: try Data(contentsOf: logURL), encoding: .utf8) ?? ""
                        continuation.resume(returning: (
                            process.terminationStatus,
                            output
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellable.cancel()
        }
    }
}

private enum LocalWhisperError: LocalizedError {
    case runtimeNotConfigured
    case runtimeUnavailable
    case invalidDuration
    case workerMissing
    case outputMissing
    case outputInvalid
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotConfigured: return "请在偏好设置中填写 Python / Whisper 运行时路径。"
        case .runtimeUnavailable: return "指定的 Python / Whisper 运行时不可执行。"
        case .invalidDuration: return "无法读取音频时长。"
        case .workerMissing: return "应用缺少本地 Whisper 转写组件。"
        case .outputMissing: return "本地 Whisper 未生成转写文件。"
        case .outputInvalid: return "本地 Whisper 的转写文件格式无效。"
        case .processFailed(let message): return "本地 Whisper 运行失败：\(message)"
        }
    }
}

