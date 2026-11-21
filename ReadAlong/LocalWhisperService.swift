import Foundation
import WhisperKit

struct TimedTranscriptWord: Sendable { let text: String; let start: Double; let end: Double }
struct WhisperTranscription: Sendable { let text: String; let words: [TimedTranscriptWord] }

@MainActor
final class LocalWhisperConfiguration: ObservableObject {
    @Published var localWhisperEnabled: Bool { didSet { UserDefaults.standard.set(localWhisperEnabled, forKey: "localWhisperEnabled") } }
    init() { localWhisperEnabled = UserDefaults.standard.bool(forKey: "localWhisperEnabled") }
}

protocol LocalTranscriptionBackend { func transcribe(audioURL: URL) async throws -> WhisperTranscription }
enum LocalWhisperService { static let backend: any LocalTranscriptionBackend = WhisperKitTranscriptionBackend() }

private struct WhisperKitTranscriptionBackend: LocalTranscriptionBackend {
    func transcribe(audioURL: URL) async throws -> WhisperTranscription {
        #if os(macOS)
        let whisperKit = try await WhisperKit(WhisperKitConfig(model: "large-v3-v20240930_626MB", verbose: false))
        let segments = try await whisperKit.transcribe(audioPath: audioURL.path, decodeOptions: DecodingOptions(language: "en", wordTimestamps: true))
        return WhisperTranscription(text: segments.map(\.text).joined(separator: " "), words: segments.flatMap { result in
            result.segments.flatMap { segment in
                (segment.words ?? []).map { TimedTranscriptWord(text: $0.word, start: Double($0.start), end: Double($0.end)) }
            }
        })
        #else
        throw LocalTranscriptionError.unavailable
        #endif
    }
}

private enum LocalTranscriptionError: LocalizedError {
    case unavailable
    var errorDescription: String? { "本地高精度转写仅适用于 macOS。" }
}
