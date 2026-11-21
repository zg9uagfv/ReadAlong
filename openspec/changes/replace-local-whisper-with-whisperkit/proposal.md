# Replace local Whisper with WhisperKit

## Goal

Make local high-accuracy transcription work without a Python runtime. Keep the existing playback and word-highlighting flow. If WhisperKit fails, automatically use the system speech recognizer and tell the reader that word-level timing might be unavailable.

## Scope

- Add WhisperKit as the only local high-accuracy backend on macOS.
- Remove WhisperMLX, the bundled Python worker, setup script, and Python/model-path preferences.
- Keep one simple setting that enables local high-accuracy transcription.
- Preserve the existing system recognizer as the fallback path.

## Non-goals

- Add cloud transcription.
- Support selecting models or runtimes in the user interface.
- Change playback controls or text formatting outside transcription results.

## Design

Use a `LocalTranscriptionBackend` protocol whose result is the existing `WhisperTranscription` value. Its concrete macOS implementation is WhisperKit. `ContentView` owns the single attempt sequence:

1. If local high-accuracy transcription is enabled, call WhisperKit.
2. On success, append or apply the timed result as today.
3. On any non-cancellation error, start `AudioPlaybackController` system transcription and record a user-facing fallback notice.

The system recognizer owns its existing permission and availability failures. The fallback notice must say that precise word synchronization is unavailable when the result has no usable word timing.

## Architecture alternatives

1. Call WhisperKit directly from `ContentView`. Rejected because it couples view state to inference setup and obscures the fallback boundary.
2. Replace `LocalWhisperService` with a protocol-backed WhisperKit service. Selected because callers keep one typed `WhisperTranscription` boundary and the backend can be tested or replaced without changing view logic.

## Acceptance criteria

- macOS Debug build resolves the WhisperKit package and compiles.
- The preferences page shows only a local high-accuracy transcription control and explanatory copy. It shows no Python path, model identifier, or model directory.
- A successful WhisperKit result supplies existing timed-word playback behavior.
- A WhisperKit failure begins system speech recognition automatically, preserves playback, and displays a fallback notice about possibly missing precise word synchronization.
- Cancelling import or transcription never triggers fallback.
- No source or README path remains that instructs users to install WhisperMLX, Python, NLTK, or `whisper-worker.py`.
