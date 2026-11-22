# Tasks

- [x] **常规任务**: Review and own the existing preferences, empty-state, app icon, and UI proposal changes. Fix any implementation or asset-catalog issues found. Acceptance: changes match `proposal.md`, with no unrelated edits.
- [x] **常规任务**: Build macOS Debug and Release configurations and launch the Release app. Acceptance: both builds succeed and Launch Services opens the app without `kLSNoExecutableErr`.
- [x] **常规任务**: Review all tracked and untracked changes against the proposal and repository rules. Acceptance: `review_report.md` begins with `VERDICT: PASS` and records the build/launch evidence.

## Verification

- Debug: `xcodebuild -project ReadAlong.xcodeproj -scheme ReadAlong -destination 'platform=macOS' -configuration Debug -derivedDataPath /private/tmp/readalong-ui-refresh-derived-data CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**.
- Release: `xcodebuild -project ReadAlong.xcodeproj -scheme ReadAlong -destination 'platform=macOS' -configuration Release -derivedDataPath /private/tmp/readalong-ui-preview-release CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**.
- Launch: `open -n /private/tmp/readalong-ui-preview-release/Build/Products/Release/ReadAlong.app` — exit code 0; Launch Services returned no `kLSNoExecutableErr`.
- Asset: `AppIcon.png` is 1024 × 1024 pixels and matches both catalog entries.
- Diff hygiene: `git diff --check` — passed.
