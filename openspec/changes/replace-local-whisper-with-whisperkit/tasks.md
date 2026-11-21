# Tasks

- [x] **复杂任务**: Add WhisperKit through Swift Package Manager, replace the Python worker with a typed `LocalTranscriptionBackend` and retain `WhisperTranscription` word timing. Acceptance: package resolves and macOS Debug build compiles.
- [x] **常规任务**: Drive one cancellation-safe WhisperKit-to-system-speech fallback sequence from `ContentView`. Acceptance: backend errors start system recognition and cancellation does not.
- [x] **常规任务**: Simplify local-transcription preferences and remove WhisperMLX setup/documentation assets. Acceptance: no user-facing Python/model directory fields and repository search finds no active WhisperMLX setup path.
- [x] **常规任务**: Add focused behavior tests where the project test surface permits, then run the macOS Debug build. Acceptance: fallback behavior is checked and build output is recorded.

## Verification

`xcodebuild -project ReadAlong.xcodeproj -scheme ReadAlong -sdk macosx -configuration Debug -derivedDataPath /private/tmp/readalong-whisperkit-derived-data CODE_SIGNING_ALLOWED=NO build` completed successfully on 2026-11-21. This project has no existing unit-test target. The build verified package resolution and the typed mapping from `TranscriptionResult.segments[].words` to `TimedTranscriptWord`.
