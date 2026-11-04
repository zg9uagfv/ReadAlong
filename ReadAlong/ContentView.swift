import SwiftUI
import UniformTypeIdentifiers
#if canImport(Translation)
import Translation
#endif

struct ContentView: View {
    @StateObject private var speech = SpeechController()
    @StateObject private var audio = AudioPlaybackController()
    @StateObject private var localWhisperConfiguration = LocalWhisperConfiguration()
    @StateObject private var elevenLabsSpeechConfiguration = ElevenLabsSpeechConfiguration()
    @State private var text = ""
    @AppStorage("lastReadingArticleText") private var lastReadingArticleText = ""
    @AppStorage("lastReadingWordIndex") private var lastReadingWordIndex = 0
    @AppStorage("lastReadingSpeed") private var savedReadingSpeed = 0.45
    @State private var readingSentences: [ReadingSentence] = []
    @State private var accent: EnglishAccent = .american
    @State private var speed = 0.45
    @State private var settingsUpdateTask: Task<Void, Never>?
    @State private var localWhisperTask: Task<Void, Never>?
    @State private var localWhisperRequestID = UUID()
    @AppStorage("childModeEnabled") private var childMode = false
    @AppStorage("childWordPause") private var wordPause = 0.5
    @State private var fontSize = 18.0
    @State private var fontStyle = DisplayFontStyle.system
    @State private var highlightedTokens: Set<String> = []
    @State private var selectedVoiceIdentifier = ""
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var isEditingText = true
    @State private var audioTranscriptText = ""
    @State private var selectedWord: WordSelection?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isScrubbingReadingProgress = false
    @State private var pendingReadingWordIndex = 0.0
    @State private var usesTTSForAudio = false
    @State private var audioPlaybackRate = 1.0
    @State private var audioPlaybackRateInput = "1.0"
    @State private var recentArticles: [RecentArticle] = []
    @State private var isShowingLibrary = false
    @State private var loopStart: Double?
    @State private var loopHint: String?
    /// Terminal transcription copy already shown and dismissed. The model status
    /// can stay for the progress tooltip; the footnote must not keep showing it.
    @State private var dismissedTranscriptionNotice: String?
    @AppStorage("showsChineseTranslation") private var showsChineseTranslation = false
    @State private var chineseTranslations: [Int: String] = [:]
    @State private var isTranslating = false
    @State private var translationStatus = ""
    @State private var translationError: String?
    @State private var translationTask: Task<Void, Never>?
    @State private var appleTranslationPassages: [String] = []
    @State private var appleTranslationRequestID = UUID()
    @AppStorage("readalongTheme") private var themeMode = ReaderThemeMode.classic.rawValue
    @FocusState private var isAudioPlaybackRateFocused: Bool

    private var wordCount: Int {
        readingSentences.last.map { $0.wordOffset + $0.tokens.count } ?? 0
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PreferencesView(
                localWhisperConfiguration: localWhisperConfiguration,
                elevenLabsSpeechConfiguration: elevenLabsSpeechConfiguration,
                accent: $accent,
                selectedVoiceIdentifier: $selectedVoiceIdentifier,
                speed: $speed,
                childMode: $childMode,
                wordPause: $wordPause,
                fontStyle: $fontStyle,
                fontSize: $fontSize,
                themeMode: $themeMode
            )
            .navigationSplitViewColumnWidth(245)
        } detail: {
            NavigationStack {
                ZStack {
                    ReaderCanvasBackground(themeMode: themeMode).ignoresSafeArea()
                    VStack(spacing: audio.isTranscribing ? 10 : 20) {
                        header
                        if !audio.isTranscribing {
                            readingOverview
                        }
                        if isEditingText {
                            editor
                        } else {
                            readingView
                        }
                    }
                    .padding(audio.isTranscribing ? 16 : 24)
                }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsPlaybackBar {
                    playbackBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .background(ReaderCanvasBackground(themeMode: themeMode))
                        .zIndex(1)
                }
            }
            .onChange(of: accent) { _ in
                if !EnglishVoiceOption.available(for: accent).contains(where: { $0.identifier == selectedVoiceIdentifier }) {
                    selectedVoiceIdentifier = ""
                }
                applyLiveSettings(debounced: false)
            }
            .onChange(of: selectedVoiceIdentifier) { _ in
                applyLiveSettings(debounced: false)
            }
            .onChange(of: speed) { _ in
                savedReadingSpeed = speed
                applyLiveSettings(debounced: true)
            }
            .onChange(of: audioPlaybackRate) { value in
                audio.setPlaybackRate(Float(value))
                if !isAudioPlaybackRateFocused {
                    audioPlaybackRateInput = String(format: "%.1f", value)
                }
            }
            .onChange(of: wordPause) { _ in
                applyLiveSettings(debounced: true)
            }
            .onChange(of: childMode) { _ in
                if speech.isSpeaking && speech.isReadingArticle {
                    seekTextReading(to: speech.currentSpokenWordIndex ?? 0)
                }
            }
            .onChange(of: usesTTSForAudio) { _ in
                commitAudioPlaybackRateInput()
                isAudioPlaybackRateFocused = false
                audio.pause()
                speech.stop()
                pendingReadingWordIndex = 0
                isScrubbingReadingProgress = false
                discardLoopSelection()
            }
            .onChange(of: audio.isTranscribing) { isTranscribing in
                if isTranscribing { dismissedTranscriptionNotice = nil }
            }
            .onChange(of: themeMode) { mode in
                ReaderTheme.setMode(mode)
            }
            .onChange(of: speech.isSpeaking) { isSpeaking in
                // The system synthesizer clears its active word when the final
                // utterance completes. Reset the slider's stored
                // position too, so a finished article visibly returns home.
                if !isSpeaking {
                    isScrubbingReadingProgress = false
                    pendingReadingWordIndex = 0
                }
            }
            .onChange(of: audio.transcriptionText) { transcription in
                guard !transcription.isEmpty else { return }
                let formattedTranscript = EnglishTextFormatter.formatArticle(transcription)
                audioTranscriptText = formattedTranscript
                text = formattedTranscript
                isEditingText = false
            }
            .onChange(of: text) { updatedText in
                lastReadingArticleText = updatedText
                saveRecentArticle(text: updatedText, position: lastReadingWordIndex)
                updateReadingSentences(for: updatedText)
                scheduleTranslation(for: updatedText)
                guard isEditingText,
                      audio.hasAudio,
                      updatedText != audioTranscriptText else { return }
                // The source text has diverged from the audio transcript. Keeping
                // the old player here would make the play button use stale audio.
                cancelAudioTranscription()
                discardLoopSelection()
                audio.unload()
                speech.stop()
            }
            .onChange(of: showsChineseTranslation) { enabled in
                if enabled { scheduleTranslation(for: text, immediately: true) }
                else {
                    translationTask?.cancel()
                    isTranslating = false
                    translationStatus = ""
                    translationError = nil
                }
            }
            .background {
                appleTranslationRunner
            }
            .navigationTitle("英语伴读")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false,
                onCompletion: importFile
            )
            .onChange(of: speech.lastError) { newError in
                if let newError { errorMessage = newError }
            }
            .onChange(of: activeSpokenWordIndex) { index in
                if let index {
                    lastReadingWordIndex = index
                    saveRecentArticle(text: text, position: index)
                }
            }
            .onAppear {
                ReaderTheme.setMode(themeMode)
                loadRecentArticles()
                speed = savedReadingSpeed
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !lastReadingArticleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                text = lastReadingArticleText
                pendingReadingWordIndex = Double(lastReadingWordIndex)
                isEditingText = false
            }
            .alert("提示", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(ReaderTheme.primary)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingLibrary) {
            NavigationStack {
                List(recentArticles) { item in
                    Button {
                        text = item.text
                        pendingReadingWordIndex = Double(item.position)
                        isEditingText = false
                        isShowingLibrary = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).lineLimit(1)
                            Text("第 \(item.position + 1) 个词继续 · \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("最近阅读")
            }
            .frame(minWidth: 420, minHeight: 360)
        }
    }

    private var header: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 720
            Group {
                if isCompact {
                    HStack(spacing: 12) {
                        headerIcon
                        headerCompactText
                        Spacer(minLength: 4)
                        headerCompactActions
                    }
                } else {
                    HStack(spacing: 16) {
                        headerIcon
                        headerText
                        Spacer(minLength: 8)
                        headerActions
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(ReaderTheme.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .frame(height: 84)
    }

    private var readingOverview: some View {
        HStack(spacing: 12) {
            overviewCard(
                title: "WORDS",
                value: wordCount.formatted(),
                note: "文章总词数",
                symbol: "textformat.abc",
                accent: ReaderTheme.primary
            )
            overviewCard(
                title: "PROGRESS",
                value: "\(wordCount == 0 ? 0 : readingCompletedWordCount * 100 / wordCount)%",
                note: wordCount == 0 ? "开始阅读后更新" : "已读 \(readingCompletedWordCount) / \(wordCount) 词",
                symbol: "chart.line.uptrend.xyaxis",
                accent: ReaderTheme.mint
            )
            overviewCard(
                title: "MODE",
                value: childMode ? "儿童模式" : "自由阅读",
                note: elevenLabsSpeechConfiguration.provider.title,
                symbol: childMode ? "figure.and.child.holdinghands" : "speaker.wave.2",
                accent: ReaderTheme.tertiary
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func overviewCard(title: String, value: String, note: String, symbol: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(ReaderTheme.overviewMuted)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(ReaderTheme.canvasText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(note)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ReaderTheme.overviewMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderTheme.overviewSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(ReaderTheme.overviewBorder, lineWidth: 1)
        }
    }

    private var headerIcon: some View {
        Image(systemName: childMode ? "figure.and.child.holdinghands" : "book.closed.fill")
            .font(.title2.weight(.bold))
            .foregroundStyle(ReaderTheme.canvasText)
            .frame(width: 52, height: 52)
            .background(ReaderTheme.heroGradient, in: Circle())
            .shadow(color: ReaderTheme.primary.opacity(0.25), radius: 8, y: 4)
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(childMode ? "一起读英语吧！" : "英语伴读")
                .font(.system(size: 28, weight: .semibold))
            Text(lastReadingArticleText.isEmpty ? "粘贴内容，或选择文本、Markdown、音频文件" : "已恢复上次阅读，可从第 \(lastReadingWordIndex + 1) 个词继续")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("\(wordCount) 个单词 · \(childMode ? "儿童慢速模式" : "自由阅读模式")")
                .font(.caption.weight(.medium))
                .foregroundStyle(ReaderTheme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerCompactText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(childMode ? "一起读英语吧！" : "英语伴读")
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
            Text("\(wordCount) 个单词 · \(childMode ? "儿童慢速模式" : "自由阅读模式")")
                .font(.caption.weight(.medium))
                .foregroundStyle(ReaderTheme.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { headerPrimaryAction; headerSecondaryActions }
            VStack(alignment: .leading, spacing: 8) {
                headerPrimaryAction
                headerSecondaryActions
            }
        }
    }

    private var headerCompactActions: some View {
        Menu {
            Button {
                if isEditingText { text = EnglishTextFormatter.formatArticle(text) }
                isEditingText.toggle()
            } label: {
                Label(isEditingText ? "进入阅读" : "编辑文本", systemImage: isEditingText ? "play.circle.fill" : "square.and.pencil")
            }

            Button { isImporting = true } label: {
                Label("选择文件", systemImage: "doc.badge.plus")
            }

            Button { text = EnglishTextFormatter.formatArticle(text) } label: {
                Label("自动排版", systemImage: "text.alignleft")
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(action: toggleChineseTranslation) {
                Label("中文翻译", systemImage: showsChineseTranslation ? "character.book.closed.fill" : "character.book.closed")
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button { isShowingLibrary = true } label: {
                Label("最近", systemImage: "clock.arrow.circlepath")
            }
        } label: {
            Label("操作", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(ReaderFilledButtonStyle(isBlackTheme: ReaderTheme.isBlackTheme, isProminent: true))
        .accessibilityLabel("文章操作")
    }

    private var headerPrimaryAction: some View {
        Button {
            if isEditingText { text = EnglishTextFormatter.formatArticle(text) }
            isEditingText.toggle()
        } label: {
            Label(isEditingText ? "进入阅读" : "编辑文本", systemImage: isEditingText ? "play.circle.fill" : "square.and.pencil")
        }
        .buttonStyle(ReaderFilledButtonStyle(isBlackTheme: ReaderTheme.isBlackTheme, isProminent: true))
    }

    private var headerSecondaryActions: some View {
        HStack(spacing: 8) {
            Button { isImporting = true } label: {
                Label("选择文件", systemImage: "doc.badge.plus")
            }
            .buttonStyle(ReaderOutlinedButtonStyle(isBlackTheme: ReaderTheme.isBlackTheme))
            Menu {
                Button("自动排版") { text = EnglishTextFormatter.formatArticle(text) }
                Button(showsChineseTranslation ? "关闭中文" : "显示中文", action: toggleChineseTranslation)
                Button("最近阅读") { isShowingLibrary = true }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
            .buttonStyle(ReaderOutlinedButtonStyle(isBlackTheme: ReaderTheme.isBlackTheme))
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: fontSize, design: fontStyle.design))
                .lineSpacing(max(2, fontSize * 0.22))
                .padding(10)
                .scrollContentBackground(.hidden)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("从这里开始阅读")
                        .font(.title3.weight(.semibold))
                    Text("粘贴一段英文、输入内容，或使用右上角“选择文件”导入文章和音频。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("导入音频后会自动生成可跟读的文本", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(ReaderTheme.primary)
                }
                .padding(28)
                .allowsHitTesting(false)
            }
        }
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ReaderTheme.border, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readingView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                readingContent
            }
            .onChange(of: activeSpokenWordIndex) { index in
                guard let index else { return }
                guard index % 12 == 0 || readingSentences.contains(where: { $0.wordOffset == index }) else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("spoken-word-\(index)", anchor: .center)
                }
            }
        }
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ReaderTheme.border, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var readingContent: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed").font(.largeTitle).foregroundStyle(.secondary)
                Text("没有文章").font(.headline)
                Text("请切换到编辑模式输入内容或选择文件").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            LazyVStack(alignment: .leading, spacing: max(8, fontSize * 0.42)) {
                ForEach(readingSentences.indices, id: \.self) { sentenceIndex in
                    let sentence = readingSentences[sentenceIndex]
                    let tokens = sentence.tokens
                    VStack(alignment: .leading, spacing: 6) {
                        WrappingLayout(spacing: max(2, fontSize * 0.12)) {
                            ForEach(tokens.indices, id: \.self) { tokenIndex in
                                readingTokenView(
                                    tokens[tokenIndex],
                                    id: "\(sentenceIndex)-\(tokenIndex)",
                                    wordIndex: sentence.wordOffset + tokenIndex,
                                    isSentenceStart: tokenIndex == 0
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if showsChineseTranslation, let translation = chineseTranslations[sentenceIndex] {
                            Text(translation)
                                .font(.system(size: max(14, fontSize * 0.82), design: fontStyle.design))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showsChineseTranslation && isTranslating {
                    Label(translationStatus.isEmpty ? "正在翻译中文…" : translationStatus, systemImage: "character.book.closed")
                        .font(.callout)
                        .foregroundStyle(ReaderTheme.primary)
                } else if showsChineseTranslation, let translationError {
                    HStack(spacing: 10) {
                        Label(translationError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Button("重试") {
                            scheduleTranslation(for: text, immediately: true)
                        }
                        .buttonStyle(ReaderOutlinedButtonStyle(isBlackTheme: ReaderTheme.isBlackTheme))
                    }
                }

                if !readingSentences.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "hand.tap")
                            .foregroundStyle(ReaderTheme.primary)
                        Text("单击句首朗读 · 单击单词标记 · 双击查看词义")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func readingTokenView(_ token: ReadingToken, id: String, wordIndex: Int, isSentenceStart: Bool) -> some View {
        let word = token.lookupWord
        let isCurrentlySpoken = activeSpokenWordIndex == wordIndex
        let hasBeenRead = (activeSpokenWordIndex ?? -1) >= wordIndex
        return Text(token.display)
            .font(.system(size: fontSize, design: fontStyle.design))
            .fontWeight(isCurrentlySpoken ? .bold : .regular)
            .foregroundStyle(isCurrentlySpoken ? ReaderTheme.currentWord : (hasBeenRead ? ReaderTheme.readText : ReaderTheme.canvasText))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(
                isCurrentlySpoken
                    ? ReaderTheme.currentWord.opacity(0.28)
                    : (highlightedTokens.contains(id) ? ReaderTheme.highlight.opacity(0.20) : Color.clear),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .scaleEffect(isCurrentlySpoken ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isCurrentlySpoken)
            .id("spoken-word-\(wordIndex)")
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { gesture in
                        switch gesture {
                        case .first(_):
                            // 双击始终是查词，包括句首的第一个单词。
                            guard let word else { return }
                            selectedWord = WordSelection(id: id, word: word)
                        case .second(_):
                            // 单击句首：从本句开头朗读并同步进度条；
                            // 单击其他单词：切换高亮。
                            if isSentenceStart {
                                readSentenceFromStart(at: wordIndex)
                            } else {
                                guard word != nil else { return }
                                if highlightedTokens.contains(id) {
                                    highlightedTokens.remove(id)
                                } else {
                                    highlightedTokens.insert(id)
                                }
                            }
                        }
                    }
            )
            .popover(item: wordSelectionBinding(for: id), arrowEdge: .bottom) { selection in
                WordDetailView(word: selection.word, accent: accent) {
                            speech.speakWord(selection.word, accent: accent, voiceIdentifier: selectedVoice, elevenLabsSettings: elevenLabsSettings, deepgramSettings: deepgramSettings)
                }
            }
            .help(tokenHelp(isSentenceStart: isSentenceStart, canLookUp: word != nil))
    }

    private func tokenHelp(isSentenceStart: Bool, canLookUp: Bool) -> String {
        guard canLookUp || isSentenceStart else { return "" }
        if isSentenceStart {
            return canLookUp ? "单击从本句开头朗读，双击查看音标和词义" : "单击从本句开头朗读"
        }
        return "双击查看音标和词义，单击高亮"
    }

    /// 单击句首单词：从该句的第一个词开始（或跳转继续）朗读，并把进度条同步到句首。
    private func readSentenceFromStart(at wordIndex: Int) {
        pendingReadingWordIndex = Double(wordIndex)
        if audio.hasAudio && !usesTTSForAudio {
            audio.seek(toWordAt: wordIndex)
        } else {
            seekTextReading(to: wordIndex)
        }
    }

    private func wordSelectionBinding(for tokenID: String) -> Binding<WordSelection?> {
        Binding(
            get: { selectedWord?.id == tokenID ? selectedWord : nil },
            set: { selection in
                if selection == nil, selectedWord?.id == tokenID {
                    selectedWord = nil
                }
            }
        )
    }

    private func updateReadingSentences(for sourceText: String) {
        var result: [ReadingSentence] = []
        var offset = 0
        for sentence in EnglishTextFormatter.sentences(in: sourceText) {
            let tokens = sentence.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .map(ReadingToken.init)
            result.append(ReadingSentence(tokens: tokens, wordOffset: offset))
            offset += tokens.count
        }
        readingSentences = result
    }

    /// One bottom bar for original audio, TTS, and a text file with no audio.
    /// Row order stays progress, transport, then settings. Only labels and bindings change.
    private var showsPlaybackBar: Bool {
        audio.hasAudio || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var usesOriginalAudio: Bool {
        audio.hasAudio && !usesTTSForAudio
    }

    private var playbackBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            playbackProgressRow
            if audio.isTranscribing {
                transcriptionStatusRow
            } else if let notice = terminalTranscriptionNotice {
                transcriptionNoticeRow(notice)
            }
            playbackTransportRow
            if let loopHint {
                Text(loopHint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(loopHint)
            }
            playbackSettingsRow
            if !audio.isTranscribing, let footnote = playbackFootnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ReaderTheme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var playbackProgressRow: some View {
        playbackProgressChrome(
            title: usesOriginalAudio ? originalAudioProgressTitle : "文章朗读进度",
            systemImage: usesOriginalAudio ? "waveform" : "text.line.first.and.arrowtriangle.forward",
            value: usesOriginalAudio ? originalAudioProgressValue : wordProgressValue,
            accessibilityValue: usesOriginalAudio ? originalAudioProgressValue : wordProgressAccessibilityValue
        ) {
            if usesOriginalAudio {
                audioTimeSlider
            } else {
                wordProgressSlider
            }
        }
    }

    private var originalAudioProgressTitle: String {
        let name = audio.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "原音频" : name
    }

    private var originalAudioProgressValue: String {
        "\(audio.formattedTime(audio.currentTime)) / \(audio.formattedTime(audio.duration))"
    }

    private var wordProgressValue: String {
        "\(readingCompletedWordCount) / \(wordCount) 词"
    }

    private var wordProgressAccessibilityValue: String {
        "已定位到第 \(readingCompletedWordCount) 个词，共 \(wordCount) 个单词；拖动后从目标位置开始或继续朗读"
    }

    private var readingCompletedWordCount: Int {
        min(
            max(0, speech.isSpeaking ? (activeSpokenWordIndex ?? -1) + 1 : Int(pendingReadingWordIndex.rounded())),
            wordCount
        )
    }

    private var readingProgressMaximumIndex: Int {
        max(0, wordCount - 1)
    }

    private var playbackProgressHelp: String {
        if audio.hasAudio {
            let trimmedStatus = audio.transcriptionStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = trimmedStatus.isEmpty
                ? (audio.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "尚未识别音频文本" : "已识别音频文本")
                : trimmedStatus
            let name = audio.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? status : "\(name)。\(status)"
        }
        return "拖动后从目标词开始或继续朗读"
    }

    private func playbackProgressChrome<SliderContent: View>(
        title: String,
        systemImage: String,
        value: String,
        accessibilityValue: String,
        @ViewBuilder slider: () -> SliderContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .help(playbackProgressHelp)
                Spacer(minLength: 8)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            slider()
                .controlSize(.small)
                .tint(.accentColor)
                .accessibilityLabel(title)
                .accessibilityValue(accessibilityValue)
        }
    }

    private var audioTimeSlider: some View {
        Slider(
            value: Binding(
                get: { audio.currentTime },
                set: { audio.seek(to: $0) }
            ),
            in: 0...max(audio.duration, 0.01)
        )
        .disabled(!audio.canControlPlayback)
    }

    private var wordProgressSlider: some View {
        let maximumIndex = readingProgressMaximumIndex
        let upperBound = Double(max(maximumIndex, 1))
        return Slider(
            value: Binding(
                get: {
                    let raw: Double
                    if isScrubbingReadingProgress {
                        raw = pendingReadingWordIndex
                    } else if speech.isSpeaking {
                        raw = Double(min(maximumIndex, activeSpokenWordIndex ?? 0))
                    } else {
                        raw = min(Double(maximumIndex), pendingReadingWordIndex)
                    }
                    return min(max(0, raw), upperBound)
                },
                set: { pendingReadingWordIndex = $0 }
            ),
            in: 0...upperBound,
            step: 1,
            onEditingChanged: { isEditing in
                guard wordCount > 1 else { return }
                isScrubbingReadingProgress = isEditing
                if isEditing {
                    pendingReadingWordIndex = Double(min(maximumIndex, activeSpokenWordIndex ?? 0))
                } else if speech.isSpeaking {
                    seekTextReading(to: Int(pendingReadingWordIndex.rounded()))
                }
            }
        )
        .disabled(wordCount <= 1)
    }

    private var playbackTransportRow: some View {
        HStack(spacing: 8) {
            if usesOriginalAudio {
                intensiveListeningMenu
                audioPlayButton
            } else {
                textPauseButton
                textPlayButton
            }
            Spacer(minLength: 0)
        }
    }

    private var intensiveListeningMenu: some View {
        Menu {
            Button { audio.skip(by: -15) } label: { Label("后退 15 秒", systemImage: "gobackward.15") }
            Button { audio.skip(by: 15) } label: { Label("前进 15 秒", systemImage: "goforward.15") }
            Button {
                if let start = loopStart {
                    if audio.setLoop(start: start, end: audio.currentTime) {
                        loopStart = nil
                        loopHint = nil
                    } else {
                        loopHint = "B 点需晚于 A 至少 0.3 秒"
                    }
                } else {
                    loopStart = audio.currentTime
                    loopHint = nil
                }
            } label: {
                Label(loopStart == nil ? "设 A 点" : "设 B 点", systemImage: "repeat")
            }
            Divider()
            Button {
                discardLoopSelection()
            } label: {
                Label("清除循环", systemImage: "xmark.circle")
            }
            .disabled(!audio.hasLoop && loopStart == nil)
        } label: {
            Label(audio.hasLoop ? "精听 · 循环中" : "精听", systemImage: "repeat")
        }
        .buttonStyle(ReaderOutlinedButtonStyle(isBlackTheme: ReaderTheme.isBlackTheme))
    }

    private var audioPlayButton: some View {
        Button { audio.togglePlayback() } label: {
            Label(audio.isPlaying ? "暂停音频" : "播放音频", systemImage: audio.isPlaying ? "pause.fill" : "play.fill")
                .frame(minWidth: 110)
        }
        .buttonStyle(ReaderFilledButtonStyle(isBlackTheme: ReaderTheme.isBlackTheme, isProminent: true))
        .disabled(!audio.canControlPlayback)
    }

    private var textPauseButton: some View {
        Button {
            speech.togglePause()
        } label: {
            Label(speech.isPaused ? "继续" : "暂停", systemImage: speech.isPaused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(ReaderOutlinedButtonStyle(isBlackTheme: ReaderTheme.isBlackTheme))
        .disabled(!speech.isSpeaking)
    }

    private var textPlayButton: some View {
        Button {
            if speech.isSpeaking {
                speech.stop()
            } else {
                if audio.hasAudio { audio.pause() }
                isEditingText = false
                startTextReading()
            }
        } label: {
            Label(textPlayTitle, systemImage: speech.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(minWidth: 110)
        }
        .buttonStyle(ReaderFilledButtonStyle(
            isBlackTheme: ReaderTheme.isBlackTheme,
            isProminent: !speech.isSpeaking,
            color: speech.isSpeaking ? .red : nil,
            foregroundColor: speech.isSpeaking ? .white : nil
        ))
        .disabled(!speech.isSpeaking && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var textPlayTitle: String {
        if speech.isSpeaking {
            return audio.hasAudio ? "停止 TTS 朗读" : "关闭阅读"
        }
        return audio.hasAudio ? "开始 TTS 朗读" : "开始阅读"
    }

    private var playbackSettingsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                playbackSourceControl
                Spacer(minLength: 8)
                playbackRateControl
            }

            VStack(alignment: .leading, spacing: 8) {
                playbackSourceControl
                HStack {
                    Spacer(minLength: 0)
                    playbackRateControl
                }
            }
        }
    }

    @ViewBuilder
    private var playbackSourceControl: some View {
        if audio.hasAudio {
            HStack(spacing: 7) {
                Text("朗读来源")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if audio.isTranscribing {
                    Label("原音频", systemImage: "waveform")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    sourceButton("原音频", usesTTS: false)
                    sourceButton("TTS 朗读", usesTTS: true)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func sourceButton(_ title: String, usesTTS: Bool) -> some View {
        let isSelected = usesTTSForAudio == usesTTS
        return Button {
            usesTTSForAudio = usesTTS
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? ReaderTheme.canvasText : ReaderTheme.overviewMuted)
                .background(
                    isSelected ? ReaderTheme.primary.opacity(0.30) : Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? ReaderTheme.primary.opacity(0.78) : ReaderTheme.border, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var playbackRateControl: some View {
        Group {
            if usesOriginalAudio {
                audioRateControl
            } else {
                speechRateControl
            }
        }
        .frame(maxWidth: 240, alignment: .trailing)
    }

    private var audioRateControl: some View {
        HStack(spacing: 4) {
            Text("倍率")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("倍率", text: $audioPlaybackRateInput)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 58)
                .focused($isAudioPlaybackRateFocused)
                .onChange(of: audioPlaybackRateInput) { input in
                    updateAudioPlaybackRateInput(input)
                }
                .onChange(of: isAudioPlaybackRateFocused) { isFocused in
                    if !isFocused { commitAudioPlaybackRateInput() }
                }
                .onSubmit { commitAudioPlaybackRateInput() }
                .accessibilityLabel("音频播放倍率，范围 0.1 到 4")
            Text("×")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var speechRateControl: some View {
        HStack(spacing: 6) {
            Text("语速")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Slider(value: $speed, in: 0.18...0.68, step: 0.01)
                .controlSize(.small)
                .accessibilityLabel("语速")
                .accessibilityValue(String(format: "%.2f 倍", speed / 0.45))
            Text(String(format: "%.2f×", speed / 0.45))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var transcriptionStatusRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(audio.transcriptionStatus ?? "识别中，音频可随时播放")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("停止识别") { cancelAudioTranscription() }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ReaderTheme.primary)
                .accessibilityLabel("停止音频识别")
        }
    }

    /// In-progress guidance and the child-mode tip only. Cancel, failure, and
    /// other finished statuses stay out of this footnote.
    private var playbackFootnote: String? {
        guard audio.hasAudio else { return nil }
        if audio.isTranscribing {
            return "识别完成后可选择 TTS 朗读；儿童模式只影响 TTS。"
        }
        if childMode && !usesTTSForAudio {
            return "当前播放原音频；切换到 TTS 朗读后儿童模式才会生效。"
        }
        return nil
    }

    /// Failure and other finished recognition messages. Hidden once dismissed or after a few seconds.
    private var terminalTranscriptionNotice: String? {
        guard !audio.isTranscribing else { return nil }
        let message = audio.transcriptionStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty, message != dismissedTranscriptionNotice else { return nil }
        return message
    }

    private func transcriptionNoticeRow(_ notice: String) -> some View {
        HStack(spacing: 8) {
            Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("关闭") { dismissedTranscriptionNotice = notice }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ReaderTheme.primary)
                .accessibilityLabel("关闭识别状态")
        }
        .task(id: notice) {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            dismissedTranscriptionNotice = notice
        }
    }

    private func discardLoopSelection() {
        loopStart = nil
        loopHint = nil
        audio.clearLoop()
    }

    private func applyLiveSettings(debounced: Bool) {
        guard speech.isSpeaking else { return }
        settingsUpdateTask?.cancel()
        let delay: UInt64 = debounced ? 220_000_000 : 0
        settingsUpdateTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            speech.updatePlaybackSettings(
                accent: accent,
                speed: speed,
                wordPause: wordPause,
                voiceIdentifier: selectedVoice
            )
        }
    }

    private func startTextReading() {
        if pendingReadingWordIndex.rounded() > 0 {
            seekTextReading(to: Int(pendingReadingWordIndex.rounded()))
        } else {
            speech.speak(
                text,
                accent: accent,
                speed: speed,
                childMode: childMode,
                wordPause: wordPause,
                voiceIdentifier: selectedVoice,
                elevenLabsSettings: elevenLabsSettings,
                deepgramSettings: deepgramSettings
            )
        }
    }

    private func seekTextReading(to wordIndex: Int) {
        lastReadingWordIndex = wordIndex
        speech.seek(
            toWordAt: wordIndex,
            in: text,
            accent: accent,
            speed: speed,
            childMode: childMode,
            wordPause: wordPause,
            voiceIdentifier: selectedVoice,
            elevenLabsSettings: elevenLabsSettings,
            deepgramSettings: deepgramSettings
        )
    }

    private var elevenLabsSettings: ElevenLabsSpeechSettings? {
        elevenLabsSpeechConfiguration.settings(for: accent)
    }

    private var deepgramSettings: DeepgramSpeechSettings? {
        elevenLabsSpeechConfiguration.deepgramSettings()
    }

    private func updateAudioPlaybackRateInput(_ input: String) {
        let sanitized = sanitizedAudioPlaybackRateInput(input)
        if sanitized != input {
            audioPlaybackRateInput = sanitized
            return
        }
        guard let rate = Double(sanitized), (0.1...4.0).contains(rate) else { return }
        audioPlaybackRate = rate
    }

    private func commitAudioPlaybackRateInput() {
        let rate = Double(audioPlaybackRateInput) ?? audioPlaybackRate
        audioPlaybackRate = min(4.0, max(0.1, rate))
        audioPlaybackRateInput = String(format: "%.1f", audioPlaybackRate)
    }

    private func sanitizedAudioPlaybackRateInput(_ input: String) -> String {
        var result = ""
        var hasDecimalSeparator = false
        var decimalDigitCount = 0

        for character in input {
            if character.isWholeNumber {
                if hasDecimalSeparator {
                    guard decimalDigitCount < 1 else { continue }
                    result.append(character)
                    decimalDigitCount += 1
                } else {
                    // The allowed range never needs more than one integer digit.
                    guard result.isEmpty, character <= "4" else { continue }
                    result.append(character)
                }
            } else if character == ".", !hasDecimalSeparator {
                if result.isEmpty { result = "0" }
                result.append(character)
                hasDecimalSeparator = true
            }
        }
        return result
    }

    private var selectedVoice: String? {
        selectedVoiceIdentifier.isEmpty ? nil : selectedVoiceIdentifier
    }

    private func toggleChineseTranslation() {
        let enabled = !showsChineseTranslation
        showsChineseTranslation = enabled
        if enabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = EnglishTextFormatter.formatArticle(text)
            isEditingText = false
        }
    }

    private func loadRecentArticles() {
        guard let data = UserDefaults.standard.data(forKey: "recentReadingArticles"),
              let values = try? JSONDecoder().decode([RecentArticle].self, from: data) else { return }
        recentArticles = values
    }

    private func saveRecentArticle(text: String, position: Int) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let title = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(8).joined(separator: " ")
        let item = RecentArticle(id: content, title: title, text: content, position: position, updatedAt: Date())
        recentArticles.removeAll { $0.id == item.id }
        recentArticles.insert(item, at: 0)
        recentArticles = Array(recentArticles.prefix(12))
        if let data = try? JSONEncoder().encode(recentArticles) {
            UserDefaults.standard.set(data, forKey: "recentReadingArticles")
        }
    }

    private var activeSpokenWordIndex: Int? {
        if speech.isSpeaking { return speech.currentSpokenWordIndex }
        return audio.hasAudio && !usesTTSForAudio ? audio.currentSpokenWordIndex : nil
    }

    private func scheduleTranslation(for sourceText: String, immediately: Bool = false) {
        translationTask?.cancel()
        guard showsChineseTranslation else { return }
        let passages = EnglishTextFormatter.sentences(in: sourceText)
        chineseTranslations = [:]
        guard !passages.isEmpty else {
            chineseTranslations = [:]
            translationError = nil
            isTranslating = false
            translationStatus = ""
            return
        }
        translationTask = Task { @MainActor in
            if !immediately { try? await Task.sleep(nanoseconds: 550_000_000) }
            guard !Task.isCancelled else { return }
            isTranslating = true
            translationStatus = "正在检查本地中英文语言包…"
            translationError = nil
            if #available(macOS 15.0, iOS 18.0, *) {
                appleTranslationPassages = passages
                let requestID = UUID()
                appleTranslationRequestID = requestID
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled,
                      appleTranslationRequestID == requestID,
                      isTranslating else { return }
                isTranslating = false
                translationStatus = ""
                translationError = "本地翻译等待超时。请确认系统允许下载翻译语言包，然后重试。"
                return
            }
            isTranslating = false
            translationStatus = ""
            translationError = "中文翻译需要 macOS 15 或 iOS 18 的苹果本地翻译功能。"
        }
    }

    @ViewBuilder
    private var appleTranslationRunner: some View {
#if canImport(Translation)
        if #available(macOS 15.0, iOS 18.0, *) {
            AppleTranslationRunner(
                passages: appleTranslationPassages,
                requestID: appleTranslationRequestID,
                status: { requestID, status in
                    guard requestID == appleTranslationRequestID, showsChineseTranslation else { return }
                    translationStatus = status
                },
                completion: { requestID, result in
                guard requestID == appleTranslationRequestID, showsChineseTranslation else { return }
                switch result {
                case .success(let values):
                    chineseTranslations = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.offset, $0.element) })
                    translationError = nil
                case .failure(let error):
                    translationError = "苹果本地翻译失败：\(error.localizedDescription)"
                }
                isTranslating = false
                translationStatus = ""
            })
            .frame(width: 0, height: 0)
        }
#endif
    }

    private func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            cancelAudioTranscription()
            let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
            guard resourceValues.isDirectory != true else {
                throw FileImportError.unsupportedFormat
            }

            let contentType = resourceValues.contentType ?? UTType(filenameExtension: url.pathExtension)
            let fileExtension = url.pathExtension.lowercased()
            if contentType?.conforms(to: .audio) == true {
                usesTTSForAudio = false
                isEditingText = false
                audioTranscriptText = ""
                text = ""
                discardLoopSelection()
                let configuration = localWhisperConfiguration
                let usesLocalWhisper = configuration.localWhisperEnabled
                audio.load(
                    url: url,
                    localeIdentifier: accent.languageCode,
                    playbackRate: Float(audioPlaybackRate),
                    shouldTranscribe: !usesLocalWhisper
                )
                speech.stop()
                if usesLocalWhisper {
                    audio.beginTranscription(status: "正在使用本地 Whisper 高精度转写…")
                    let requestID = localWhisperRequestID
                    localWhisperTask = Task {
                        do {
                            try await LocalWhisperService.transcribe(url: url, configuration: configuration) { chunk, completed, total in
                                guard localWhisperRequestID == requestID else { return }
                                audio.appendWhisperChunk(chunk, completed: completed, total: total)
                            }
                            guard localWhisperRequestID == requestID else { return }
                            audio.finishTranscription(status: audio.transcriptionText.isEmpty ? "未识别到语音内容" : nil)
                        } catch {
                            guard localWhisperRequestID == requestID, !(error is CancellationError) else { return }
                            audio.finishTranscription(status: "本地 Whisper 转写失败")
                            errorMessage = "本地 Whisper 转写失败：\(transcriptionErrorMessage(error))"
                        }
                    }
                }
            } else if contentType?.conforms(to: .text) == true || ["txt", "md", "markdown"].contains(fileExtension) {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    text = EnglishTextFormatter.formatArticle(content)
                } else if let content = try? String(contentsOf: url, encoding: .ascii) {
                    text = EnglishTextFormatter.formatArticle(content)
                } else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                discardLoopSelection()
                audio.unload()
                speech.stop()
                isEditingText = false
            } else {
                throw FileImportError.unsupportedFormat
            }
        } catch {
            errorMessage = error.localizedDescription.isEmpty ? FileImportError.unsupportedFormat.localizedDescription : error.localizedDescription
        }
    }

    private func cancelAudioTranscription() {
        localWhisperRequestID = UUID()
        localWhisperTask?.cancel()
        localWhisperTask = nil
        audio.cancelTranscription()
    }

    private func transcriptionErrorMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "请求超时，请检查服务地址和网络。"
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet:
                return "无法连接服务，请检查服务地址和网络。"
            default: break
            }
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "本地 Whisper 未返回详细错误，请检查运行时路径和模型配置。" : message
    }
}

#if canImport(Translation)
@available(macOS 15.0, iOS 18.0, *)
private struct AppleTranslationRunner: View {
    let passages: [String]
    let requestID: UUID
    let status: (UUID, String) -> Void
    let completion: (UUID, Result<[String], Error>) -> Void
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .task(id: requestID) {
                guard !passages.isEmpty else { return }
                status(requestID, "正在准备本地翻译语言包…")
                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: Locale.Language(identifier: "en"),
                        target: Locale.Language(identifier: "zh-Hans")
                    )
                } else {
                    configuration?.invalidate()
                }
            }
            .translationTask(configuration) { session in
                let activeRequestID = requestID
                do {
                    status(activeRequestID, "正在检查并下载所需语言包…")
                    try await session.prepareTranslation()
                    guard !Task.isCancelled else { return }
                    status(activeRequestID, "语言包已就绪，正在翻译中文…")
                    let requests = passages.enumerated().map {
                        TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                    }
                    let responses = try await session.translations(from: requests)
                    let ordered = responses.sorted {
                        Int($0.clientIdentifier ?? "0") ?? 0 < Int($1.clientIdentifier ?? "0") ?? 0
                    }
                    completion(activeRequestID, .success(ordered.map(\.targetText)))
                } catch {
                    completion(activeRequestID, .failure(error))
                }
            }
    }
}
#endif

enum ReaderThemeMode: String, CaseIterable {
    case classic
    case black
}

enum ReaderTheme {
    static var isBlackTheme: Bool {
        UserDefaults.standard.string(forKey: "readalongTheme") == ReaderThemeMode.black.rawValue
    }

    static func setMode(_ rawValue: String) {
        UserDefaults.standard.set(rawValue, forKey: "readalongTheme")
    }

    static var primary: Color {
        isBlackTheme ? Color(red: 0.80, green: 0.70, blue: 0.47) : Color(red: 0.56, green: 0.34, blue: 1.00)
    }
    static var mint: Color {
        isBlackTheme ? Color(red: 0.48, green: 0.68, blue: 0.54) : Color(red: 0.39, green: 0.91, blue: 0.79)
    }
    static var sunshine: Color {
        isBlackTheme ? Color(red: 0.78, green: 0.67, blue: 0.42) : Color(red: 1.00, green: 0.78, blue: 0.40)
    }
    static var tertiary: Color {
        isBlackTheme ? Color(red: 0.62, green: 0.59, blue: 0.75) : Color(red: 0.80, green: 0.52, blue: 1.00)
    }
    static var canvasText: Color {
        isBlackTheme ? Color(red: 0.90, green: 0.90, blue: 0.89) : Color(red: 0.95, green: 0.92, blue: 1.00)
    }
    static var readText: Color {
        isBlackTheme ? Color(red: 0.62, green: 0.63, blue: 0.62) : Color(red: 0.74, green: 0.69, blue: 0.91)
    }
    static var currentWord: Color {
        isBlackTheme ? Color(red: 0.43, green: 0.70, blue: 0.55) : Color(red: 0.42, green: 0.94, blue: 0.77)
    }
    static var highlight: Color {
        isBlackTheme ? Color(red: 0.78, green: 0.67, blue: 0.42) : Color(red: 1.00, green: 0.81, blue: 0.39)
    }
    static var surface: Color {
        isBlackTheme ? Color(red: 0.085, green: 0.085, blue: 0.085) : Color(red: 0.055, green: 0.035, blue: 0.15).opacity(0.88)
    }
    static var border: Color {
        isBlackTheme ? Color.white.opacity(0.105) : Color(red: 0.68, green: 0.49, blue: 1.00).opacity(0.36)
    }
    static var overviewMuted: Color {
        isBlackTheme ? Color.white.opacity(0.56) : Color(red: 0.80, green: 0.76, blue: 0.90)
    }
    static var overviewSurface: Color {
        isBlackTheme ? Color(red: 0.085, green: 0.085, blue: 0.085) : Color(red: 0.075, green: 0.045, blue: 0.19).opacity(0.84)
    }
    static var overviewBorder: Color {
        isBlackTheme ? Color.white.opacity(0.11) : Color(red: 0.66, green: 0.47, blue: 1.00).opacity(0.42)
    }
    static var brandSurface: Color {
        isBlackTheme ? Color.white.opacity(0.09) : Color.white.opacity(0.10)
    }
    static var badgeSurface: Color {
        isBlackTheme ? primary.opacity(0.12) : primary.opacity(0.12)
    }
    static var buttonSurface: Color {
        isBlackTheme ? Color(red: 0.15, green: 0.15, blue: 0.15) : primary
    }
    static var buttonText: Color {
        isBlackTheme ? Color(red: 0.91, green: 0.91, blue: 0.90) : .white
    }
    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: isBlackTheme
                ? [Color(red: 0.56, green: 0.52, blue: 0.40), Color(red: 0.35, green: 0.43, blue: 0.36)]
                : [Color(red: 0.38, green: 0.21, blue: 0.92), Color(red: 0.18, green: 0.45, blue: 0.98)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    static var canvas: LinearGradient {
        LinearGradient(
            colors: isBlackTheme
                ? [Color(red: 0.055, green: 0.055, blue: 0.055), Color(red: 0.075, green: 0.075, blue: 0.075)]
                : [Color(red: 0.22, green: 0.055, blue: 0.57), Color(red: 0.075, green: 0.045, blue: 0.25), Color(red: 0.025, green: 0.055, blue: 0.16)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct ReaderCanvasBackground: View {
    var themeMode: String

    private var isBlackTheme: Bool {
        themeMode == ReaderThemeMode.black.rawValue
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: isBlackTheme
                        ? [Color(red: 0.055, green: 0.055, blue: 0.055), Color(red: 0.075, green: 0.075, blue: 0.075)]
                        : [Color(red: 0.22, green: 0.055, blue: 0.57), Color(red: 0.075, green: 0.045, blue: 0.25), Color(red: 0.025, green: 0.055, blue: 0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if !isBlackTheme {
                    let width = geometry.size.width
                    let height = geometry.size.height
                    Ellipse()
                        .fill(LinearGradient(colors: [Color(red: 0.68, green: 0.25, blue: 1.0).opacity(0.75), Color(red: 0.28, green: 0.38, blue: 1.0).opacity(0.32), .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: width * 1.25, height: height * 0.48)
                        .rotationEffect(.degrees(-18))
                        .offset(x: -width * 0.12, y: -height * 0.27)
                        .blur(radius: 58)
                    Ellipse()
                        .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.82, blue: 0.78).opacity(0.48), Color(red: 0.22, green: 0.42, blue: 1.0).opacity(0.46), .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: width * 1.1, height: height * 0.38)
                        .rotationEffect(.degrees(22))
                        .offset(x: width * 0.20, y: height * 0.13)
                        .blur(radius: 64)
                    Ellipse()
                        .fill(LinearGradient(colors: [Color(red: 0.88, green: 0.30, blue: 0.79).opacity(0.34), .clear], startPoint: .top, endPoint: .bottom))
                        .frame(width: width * 0.72, height: height * 0.38)
                        .rotationEffect(.degrees(-28))
                        .offset(x: width * 0.27, y: -height * 0.23)
                        .blur(radius: 68)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .background(Color(red: 0.025, green: 0.02, blue: 0.08))
    }
}

/// Explicit button colors keep controls legible in both light and dark system appearances.
struct ReaderFilledButtonStyle: ButtonStyle {
    var isBlackTheme = false
    var isProminent = false
    var color: Color? = nil
    var foregroundColor: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        let accentFill = Color(red: 0.72, green: 0.61, blue: 0.37)
        let fill = color ?? (isBlackTheme
            ? (isProminent ? accentFill : Color(red: 0.145, green: 0.145, blue: 0.145))
            : Color(red: 0.29, green: 0.37, blue: 0.90))
        let text = foregroundColor ?? (isBlackTheme && isProminent
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : (isBlackTheme ? Color(red: 0.93, green: 0.93, blue: 0.92) : .white))
        configuration.label
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: isBlackTheme ? 13 : 14, weight: isBlackTheme ? .medium : .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, isBlackTheme ? 13 : 14)
            .padding(.vertical, 8)
            .background(fill.opacity(configuration.isPressed ? 0.78 : 0.96), in: RoundedRectangle(cornerRadius: isBlackTheme ? 9 : 18, style: .continuous))
            .overlay {
                if isBlackTheme {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isProminent ? accentFill.opacity(0.55) : Color.white.opacity(0.24), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: isBlackTheme ? 9 : 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ReaderOutlinedButtonStyle: ButtonStyle {
    var isBlackTheme = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: isBlackTheme ? 13 : 14, weight: isBlackTheme ? .medium : .semibold))
            .foregroundStyle(isBlackTheme ? Color(red: 0.90, green: 0.90, blue: 0.89) : ReaderTheme.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isBlackTheme
                        ? Color.white.opacity(configuration.isPressed ? 0.15 : 0.075)
                        : ReaderTheme.primary.opacity(configuration.isPressed ? 0.22 : 0.12),
                        in: RoundedRectangle(cornerRadius: isBlackTheme ? 9 : 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: isBlackTheme ? 9 : 18, style: .continuous)
                    .stroke(isBlackTheme ? Color.white.opacity(0.27) : ReaderTheme.primary.opacity(0.75), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: isBlackTheme ? 9 : 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum FileImportError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "无法识别该文件格式。请上传文本或 Markdown 文件（.txt、.md、.markdown），或音频文件（如 .mp3、.m4a、.wav）。"
    }
}

private struct WordSelection: Identifiable {
    let id: String
    let word: String
}

private struct ReadingSentence {
    let tokens: [ReadingToken]
    let wordOffset: Int
}

private struct ReadingToken {
    let display: String
    let lookupWord: String?

    init(_ value: String) {
        let displayText = value + " "
        display = displayText
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "'-’"))
        let cleaned = displayText.unicodeScalars.filter { allowed.contains($0) }
        let word = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: CharacterSet(charactersIn: "'-’"))
        lookupWord = word.range(of: "^[A-Za-z]+(?:['’-][A-Za-z]+)*$", options: .regularExpression) == nil ? nil : word
    }
}

private struct RecentArticle: Identifiable, Codable {
    let id: String
    let title: String
    let text: String
    let position: Int
    let updatedAt: Date
}
