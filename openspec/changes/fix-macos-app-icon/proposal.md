# Fix the macOS app icon

## Why

The generated icon image exists in the asset catalog, but the current catalog metadata does not describe a valid macOS AppIcon slot. The built app therefore has no compiled asset catalog or `CFBundleIconName`, and Finder/Dock cannot display the icon.

## What changes

- Define the supplied icon image in a macOS-supported AppIcon slot.
- Keep the iOS universal icon entry if it remains valid for the app's iOS target.
- Verify a clean macOS app build contains the compiled asset catalog and icon metadata.

## Acceptance

- Asset Catalog compilation emits `Assets.car` and icon metadata for the macOS app.
- A clean Release build launches, and the built bundle contains the expected app icon assets.
- Reviewer reports `VERDICT: PASS`.
