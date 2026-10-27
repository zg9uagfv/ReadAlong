import SwiftUI

struct PreferencesView: View {
    @ObservedObject var localWhisperConfiguration: LocalWhisperConfiguration
    @ObservedObject var elevenLabsSpeechConfiguration: ElevenLabsSpeechConfiguration
    @Binding var accent: EnglishAccent
    @Binding var selectedVoiceIdentifier: String
    @Binding var speed: Double
    @Binding var childMode: Bool
    @Binding var wordPause: Double
    @Binding var fontStyle: DisplayFontStyle
    @Binding var fontSize: Double
    @State private var isTTSExpanded = true
    @State private var isElevenLabsExpanded = false
    @State private var isChildModeExpanded = false
    @State private var isTypographyExpanded = false
    @State private var isLocalWhisperExpanded = false
    @State private var isAboutExpanded = false

    var body: some View {
        Form {
            Section {
                DisclosureGroup(isExpanded: $isTTSExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("英语口音")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("英语口音", selection: $accent) {
                            ForEach(EnglishAccent.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 260, alignment: .leading)

                        Text("朗读引擎")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("朗读引擎", selection: $elevenLabsSpeechConfiguration.isEnabled) {
                            Text("系统语音").tag(false)
                            Text("ElevenLabs").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 260, alignment: .leading)

                        if elevenLabsSpeechConfiguration.isEnabled {
                            DisclosureGroup("配置 ElevenLabs", isExpanded: $isElevenLabsExpanded) {
                                VStack(alignment: .leading, spacing: 10) {
                                    settingField("API Key", secureValue: $elevenLabsSpeechConfiguration.apiKey)
                                    settingField("美式 Voice ID", value: $elevenLabsSpeechConfiguration.americanVoiceID)
                                    settingField("英式 Voice ID", value: $elevenLabsSpeechConfiguration.britishVoiceID)
                                    Button("填入免费示例声音") {
                                        elevenLabsSpeechConfiguration.useSampleVoices()
                                    }
                                    .buttonStyle(ReaderOutlinedButtonStyle())
                                    settingField("模型 ID", value: $elevenLabsSpeechConfiguration.modelID)
                                    if elevenLabsSpeechConfiguration.settings(for: accent) == nil {
                                        Label("请填写 API Key 和当前口音对应的 Voice ID。", systemImage: "exclamationmark.triangle")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    Text("API Key 保存在本机钥匙串；Voice ID 可从 My Voices 复制。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 4)
                            }
                        } else {
                            Text("系统声音")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Picker("系统声音", selection: $selectedVoiceIdentifier) {
                                Text("自动选择高品质").tag("")
                                ForEach(EnglishVoiceOption.available(for: accent)) { voice in
                                    Text(voice.displayName).tag(voice.identifier)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Label(
                                hasHighQualityVoice ? "可使用已下载的高质量系统声音" : "可在系统设置中下载高质量英语声音",
                                systemImage: hasHighQualityVoice ? "speaker.wave.2" : "arrow.down.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("前往“系统设置 → 辅助功能 → 朗读内容 → 系统声音 → 管理声音”，下载 English (US) 或 English (UK) 的 Enhanced / Premium 声音。")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("语速")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            HStack {
                                Slider(value: $speed, in: 0.18...0.68, step: 0.01)
                                HStack(spacing: 2) {
                                    TextField(
                                        "",
                                        value: speedMultiplier,
                                        format: .number.precision(.fractionLength(0...2))
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .frame(width: 52)
                                    .accessibilityLabel("语速倍率")
                                    Text("×")
                                }
                                .frame(width: 64, alignment: .trailing)
                            }
                        }
                        Text(elevenLabsSpeechConfiguration.isEnabled
                            ? "在线语音已启用；详细参数在“配置 ElevenLabs”中调整。"
                            : "点词与文章朗读使用设备声音。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("TTS 发音", systemImage: "speaker.wave.2.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { isTTSExpanded.toggle() }
                }

                DisclosureGroup(isExpanded: $isTypographyExpanded) {
                    Picker("字体", selection: $fontStyle) {
                        ForEach(DisplayFontStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    LabeledContent("字号") {
                        HStack {
                            Slider(value: $fontSize, in: 14...34, step: 1)
                            Text("\(Int(fontSize)) pt")
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(.system(size: min(fontSize, 26), design: fontStyle.design))
                        .padding(.vertical, 6)
                } label: {
                    Label("文字显示", systemImage: "textformat.size")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { isTypographyExpanded.toggle() }
                }
            } header: {
                Label("常用阅读设置", systemImage: "slider.horizontal.3")
            }

            Section {
                DisclosureGroup(isExpanded: $isChildModeExpanded) {
                        Toggle("启用儿童模式", isOn: $childMode)
                        if childMode {
                            LabeledContent("单词间停顿") {
                                HStack {
                                    Slider(value: $wordPause, in: 0.0...2.0, step: 0.5)
                                    HStack(spacing: 2) {
                                        TextField(
                                            "",
                                            value: wordPauseInput,
                                            format: .number.precision(.fractionLength(0...2))
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .multilineTextAlignment(.trailing)
                                        .monospacedDigit()
                                        .frame(width: 52)
                                        .accessibilityLabel("单词间停顿秒数")
                                        Text("秒")
                                    }
                                    .frame(width: 64, alignment: .trailing)
                                }
                            }
                        }
                        Text(elevenLabsSpeechConfiguration.isEnabled
                            ? "先合成整段语音，再在本机按时间戳补足词间停顿；当前段的调整从下一段生效。"
                            : "系统语音逐词朗读，每个词结束后按设定时长停顿。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("儿童模式用于 TTS 朗读。导入音频时，请在播放区选择“TTS 朗读”；播放原音频不会改变其语速和停顿。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                } label: {
                        Label("儿童模式", systemImage: "figure.and.child.holdinghands")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { isChildModeExpanded.toggle() }
                }
            } header: {
                Label("学习模式", systemImage: "graduationcap")
            }

            Section {
                DisclosureGroup(isExpanded: $isLocalWhisperExpanded) {
                    Toggle("优先使用本地 Whisper（仅 macOS）", isOn: $localWhisperConfiguration.localWhisperEnabled)
                    if localWhisperConfiguration.localWhisperEnabled {
                        TextField("模型名", text: $localWhisperConfiguration.localWhisperModel)
                        TextField("模型目录（可选）", text: $localWhisperConfiguration.localWhisperModelDirectory)
                        TextField("Python / Whisper 运行时路径", text: $localWhisperConfiguration.localWhisperPythonPath)
                    }
                    Text("MacBook 上可配置例如 whisper-large-v3-turbo；iPad 使用系统语音识别。运行时路径需指向已安装 whispermlx 的 Python。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("本地 Whisper", systemImage: "laptopcomputer")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { isLocalWhisperExpanded.toggle() }
                }

                DisclosureGroup(isExpanded: $isAboutExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "book.pages.fill")
                                .font(.title2)
                                .foregroundStyle(brandColor)
                                .frame(width: 42, height: 42)
                                .background(brandColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("ReadAlong · 英语伴读")
                                    .font(.headline)
                                Text("版本 \(appVersion)（构建 \(buildNumber)）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("更新日志")
                                .font(.subheadline.weight(.semibold))
                            Text("版本 2.5")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(brandColor)
                            changelogRow("音频导入后可立即播放、暂停与拖动进度，识别中途可停止并保留已识别文字")
                            changelogRow("导入音频默认播放原音频，识别完成后可切换为 TTS 朗读识别文字")
                            changelogRow("本地 Whisper 改为单进程增量转写，一次加载模型并逐段显示结果")
                            changelogRow("语音设置支持直接输入数值")
                            changelogRow("新增“关于”面板与更新日志")
                            Divider()
                            Text("版本 2.4")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(brandColor)
                            changelogRow("全新名称：ReadAlong · 英语伴读")
                            changelogRow("移除大模型服务与远程翻译回退")
                            changelogRow("中文翻译改为仅使用苹果本地翻译")
                            changelogRow("保留本地 Whisper 与系统语音识别")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                } label: {
                    Label("关于与版本信息", systemImage: "info.circle")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { isAboutExpanded.toggle() }
                }
            } header: {
                Label("高级与关于", systemImage: "gearshape.2")
            }
            }
        .formStyle(.grouped)
        .font(.body)
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [Color(red: 0.94, green: 0.96, blue: 1.00), Color(red: 0.96, green: 1.00, blue: 0.96)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .tint(Color(red: 0.29, green: 0.37, blue: 0.90))
        .navigationTitle("偏好设置")
    }

    private var speedMultiplier: Binding<Double> {
        Binding(
            get: { speed / 0.45 },
            set: { multiplier in
                speed = min(max(multiplier * 0.45, 0.18), 0.68)
            }
        )
    }

    @ViewBuilder
    private func settingField(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(title, text: value)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func settingField(_ title: String, secureValue: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            SecureField(title, text: secureValue)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var wordPauseInput: Binding<Double> {
        Binding(
            get: { wordPause },
            set: { pause in
                wordPause = min(max(pause, 0), 2)
            }
        )
    }

    private var hasHighQualityVoice: Bool {
        EnglishVoiceOption.available(for: accent).contains {
            $0.quality == .enhanced || $0.quality == .premium
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    private var brandColor: Color {
        Color(red: 0.29, green: 0.37, blue: 0.90)
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private func changelogRow(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.hierarchical)
    }
}
