# Tasks

- [x] **常规任务**: Correct `AppIcon.appiconset/Contents.json` so the supplied 1024 × 1024 image is available in a valid macOS icon slot. Acceptance: Asset Catalog compiler recognizes the macOS icon and emits icon metadata.
- [x] **常规任务**: Build macOS Release from a fresh derived-data directory and inspect the resulting bundle. Acceptance: `Assets.car` and `CFBundleIconName` exist, and the built app opens successfully.
- [x] **常规任务**: Independently review all tracked and untracked changes. Acceptance: `review_report.md` begins with `VERDICT: PASS` and records artifact evidence.

## Verification

- Asset Catalog: `xcrun actool --compile /private/tmp/readalong-actool-output --app-icon AppIcon --accent-color AccentColor --output-partial-info-plist /private/tmp/readalong-actool-partial.plist --platform macosx --minimum-deployment-target 15.0 --target-device mac --product-type com.apple.product-type.application ReadAlong/Assets.xcassets` — exit code 0; emitted `AppIcon.icns`, `Assets.car`, and partial Info.plist.
- Release build: `xcodebuild -project ReadAlong.xcodeproj -scheme ReadAlong -destination 'platform=macOS' -configuration Release -derivedDataPath /private/tmp/readalong-icon-investigation -clonedSourcePackagesDirPath /private/tmp/readalong-ui-preview-release/SourcePackages CODE_SIGNING_ALLOWED=NO build` — **BUILD SUCCEEDED**.
- App bundle: `Contents/Resources/AppIcon.icns` and `Contents/Resources/Assets.car` exist; Info.plist contains `CFBundleIconName = AppIcon` and `CFBundleIconFile = AppIcon`.
- Launch Services: `open -n /private/tmp/readalong-icon-investigation/Build/Products/Release/ReadAlong.app` — exit code 0.
- Image slots: all ten macOS icon images match their declared pixel dimensions; source `AppIcon.png` is 1024 × 1024.
- `git diff --check` — passed.
