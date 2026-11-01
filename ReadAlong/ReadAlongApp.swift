import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct ReadAlongApp: App {
#if os(macOS)
    @NSApplicationDelegateAdaptor(ReadAlongAppDelegate.self) private var appDelegate
#endif

    @StateObject private var localWhisperConfiguration: LocalWhisperConfiguration
    @StateObject private var elevenLabsSpeechConfiguration: ElevenLabsSpeechConfiguration
    @StateObject private var readerSettings: ReaderSettings

    init() {
        // Migrate before the shared settings objects read UserDefaults.
        LegacySettingsMigration.migrateIfNeeded()
        _localWhisperConfiguration = StateObject(wrappedValue: LocalWhisperConfiguration())
        _elevenLabsSpeechConfiguration = StateObject(wrappedValue: ElevenLabsSpeechConfiguration())
        _readerSettings = StateObject(wrappedValue: ReaderSettings())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(localWhisperConfiguration)
                .environmentObject(elevenLabsSpeechConfiguration)
                .environmentObject(readerSettings)
                .frame(minWidth: 680, minHeight: 560)
        }
#if os(macOS)
        Settings {
            SettingsRoot(
                localWhisperConfiguration: localWhisperConfiguration,
                elevenLabsSpeechConfiguration: elevenLabsSpeechConfiguration,
                readerSettings: readerSettings
            )
        }
#endif
    }
}

/// macOS Settings window. It shares the same objects as the reading window so
/// speech rate, accent, and API configuration stay live while reading.
private struct SettingsRoot: View {
    @ObservedObject var localWhisperConfiguration: LocalWhisperConfiguration
    @ObservedObject var elevenLabsSpeechConfiguration: ElevenLabsSpeechConfiguration
    @ObservedObject var readerSettings: ReaderSettings

    var body: some View {
        NavigationStack {
            PreferencesView(
                localWhisperConfiguration: localWhisperConfiguration,
                elevenLabsSpeechConfiguration: elevenLabsSpeechConfiguration,
                accent: $readerSettings.accent,
                selectedVoiceIdentifier: $readerSettings.selectedVoiceIdentifier,
                speed: $readerSettings.speed,
                childMode: $readerSettings.childMode,
                wordPause: $readerSettings.wordPause,
                fontStyle: $readerSettings.fontStyle,
                fontSize: $readerSettings.fontSize
            )
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 560)
    }
}

private enum LegacySettingsMigration {
    private static let migrationKey = "didMigrateEnglishReaderSettings"
    private static let legacyBundleIdentifier = "com.example.EnglishReader"
    private static let keys = [
        "childModeEnabled",
        "childWordPause",
        "showsChineseTranslation",
        "localWhisperEnabled",
        "localWhisperModel",
        "localWhisperModelDirectory",
        "localWhisperPythonPath",
        "elevenLabsSpeechEnabled",
        "elevenLabsSpeechModelID",
        "elevenLabsAmericanVoiceID",
        "elevenLabsBritishVoiceID",
    ]

    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey),
              let legacyDefaults = UserDefaults(suiteName: legacyBundleIdentifier) else { return }

        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacyDefaults.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }
}

#if os(macOS)
final class ReadAlongAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let existingInstance = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentProcessIdentifier }
            .first

        guard let existingInstance else { return }
        existingInstance.activate(options: [])
        NSApp.terminate(nil)
    }
}
#endif
