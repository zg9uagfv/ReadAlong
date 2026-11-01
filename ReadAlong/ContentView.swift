import SwiftUI
import UniformTypeIdentifiers
#if canImport(Translation)
import Translation
#endif

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var localWhisperConfiguration: LocalWhisperConfiguration
    @EnvironmentObject private var elevenLabsSpeechConfiguration: ElevenLabsSpeechConfiguration
    @EnvironmentObject private var settings: ReaderSettings
    @StateObject private var speech = SpeechController()
    @StateObject private var audio = AudioPlaybackController()
    @State private var text = ""
    @AppStorage("lastReadingArticleText") private var lastReadingArticleText = ""
    @AppStorage("lastReadingWordIndex") private var lastReadingWordIndex = 0
    @State private var readingSentences: [ReadingSentence] = []
    @State private var settingsUpdateTask: Task<Void, Never>?
    @State private var localWhisperTask: Task<Void, Never>?
    @State private var localWhisperRequestID = UUID()
    @State private var highlightedTokens: Set<String> = []
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var isEditingText = true
    @State private var audioTranscriptText = ""
    @State private var selectedWord: WordSelection?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isScrubbingReadingProgress = false
    @State private var pendingReadingWordIndex = 0.0
    @State private var isAudioProgressVisible = true
    @State private var usesTTSForAudio = false
    @State private var audioPlaybackRate = 1.0
    @State private var recentArticles: [RecentArticle] = []
    @State private var isShowingLibrary = false
    @State private var loopStart: Double?
    @State private var loopHint: String?
    @State private var expandedWord: WordSelection?
#if os(iOS)
    @State private var isShowingPreferences = false
#endif
    @AppStorage("showsChineseTranslation") private var showsChineseTranslation = false
    @State private var chineseTranslations: [Int: String] = [:]
    @State private var isTranslating = false
    @State private var translationStatus = ""
    @State private var translationError: String?
    @State private var translationTask: Task<Void, Never>?
    @State private var appleTranslationPassages: [String] = []
    @State private var appleTranslationRequestID = UUID()

    private var accent: EnglishAccent { settings.accent }
    private var speed: Double { settings.speed }
    private var childMode: Bool { settings.childMode }
    private var wordPause: Double { settings.wordPause }
    private var fontStyle: DisplayFontStyle { settings.fontStyle }
    private var fontSize: Double { settings.fontSize }
    private var selectedVoiceIdentifier: String {
        get { settings.selectedVoiceIdentifier }
        nonmutating set { settings.selectedVoiceIdentifier = newValue }
    }
    private var hasLoadedContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var wordCount: Int {
        readingSentences.last.map { $0.wordOffset + $0.tokens.count } ?? 0
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ReadingSidebar(
                recentArticles: recentArticles,
                hasLoadedContent: hasLoadedContent,
                showsReaderLink: horizontalSizeClass == .compact,
                childMode: $settings.childMode,
                showsChineseTranslation: chineseTranslationBinding,
                accent: $settings.accent,
                onSelect: openRecentArticle,
                onShowReader: showReaderColumnIfCompact,
                onOpenPreferences: openPreferences
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            NavigationStack {
                ZStack {
                    ReaderTheme.canvas(colorScheme).ignoresSafeArea()
                    VStack(spacing: 20) {
                        if !hasLoadedContent {
                            header
                        }
                        if isEditingText {
                            editor
                        } else {
                            readingView
                        }
                        controls
                    }
                    .padding(24)
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
                applyLiveSettings(debounced: true)
            }
            .onChange(of: audioPlaybackRate) { value in
                audio.setPlaybackRate(Float(value))
            }
            .onChange(of: audio.fileName) { _ in
                loopStart = nil
                loopHint = nil
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
                audio.pause()
                speech.stop()
                pendingReadingWordIndex = 0
                isScrubbingReadingProgress = false
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
            .navigationTitle(childMode ? "一起读英语吧！" : "英语伴读")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if hasLoadedContent {
                        Button(action: toggleEditing) {
                            Label(isEditingText ? "进入阅读" : "编辑文本", systemImage: isEditingText ? "play.circle" : "square.and.pencil")
                        }
                        Button { isImporting = true } label: {
                            Label("选择文件", systemImage: "doc.badge.plus")
                        }
                        Menu {
                            Button("自动排版") { text = EnglishTextFormatter.formatArticle(text) }
                            Button(showsChineseTranslation ? "关闭中文" : "显示中文", action: toggleChineseTranslation)
                            Button("最近阅读") { isShowingLibrary = true }
                        } label: {
                            Label("更多", systemImage: "ellipsis.circle")
                        }
                    }
                    OpenPreferencesButton(action: openPreferences)
                }
            }
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
                loadRecentArticles()
                if !selectedVoiceIdentifier.isEmpty,
                   !EnglishVoiceOption.available(for: accent).contains(where: { $0.identifier == selectedVoiceIdentifier }) {
                    selectedVoiceIdentifier = ""
                }
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
        .sheet(isPresented: $isShowingLibrary) {
            NavigationStack {
                List(recentArticles) { item in
                    Button {
                        openRecentArticle(item)
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
#if os(iOS)
        .sheet(isPresented: $isShowingPreferences) {
            NavigationStack {
                preferencesForm
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { isShowingPreferences = false }
                        }
                    }
            }
        }
#endif
        .sheet(item: $expandedWord) { selection in
            NavigationStack {
                WordDetailView(word: selection.word, accent: accent, style: .full, speak: {
                    speakLookupWord(selection.word)
                })
            }
            .frame(minWidth: 420, minHeight: 480)
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
            .background(ReaderTheme.paperStrong(colorScheme), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(ReaderTheme.cardStroke(colorScheme), lineWidth: 1)
            }
            .shadow(color: ReaderTheme.primary.opacity(0.10), radius: 14, y: 6)
        }
        .frame(height: 84)
    }

    private var headerIcon: some View {
        Image(systemName: childMode ? "figure.and.child.holdinghands" : "book.closed.fill")
            .font(.title2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(ReaderTheme.heroGradient, in: Circle())
            .shadow(color: ReaderTheme.primary.opacity(0.25), radius: 8, y: 4)
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(childMode ? "一起读英语吧！" : "英语伴读")
                .font(.title3.weight(.bold))
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
                .font(.headline)
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
            Button(action: toggleEditing) {
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
        .buttonStyle(ReaderFilledButtonStyle())
        .accessibilityLabel("文章操作")
    }

    private var headerPrimaryAction: some View {
        Button(action: toggleEditing) {
            Label(isEditingText ? "进入阅读" : "编辑文本", systemImage: isEditingText ? "play.circle.fill" : "square.and.pencil")
        }
        .buttonStyle(ReaderFilledButtonStyle())
    }

    private var headerSecondaryActions: some View {
        HStack(spacing: 8) {
            Button { isImporting = true } label: {
                Label("选择文件", systemImage: "doc.badge.plus")
            }
            .buttonStyle(ReaderOutlinedButtonStyle())
            Menu {
                Button("自动排版") { text = EnglishTextFormatter.formatArticle(text) }
                Button(showsChineseTranslation ? "关闭中文" : "显示中文", action: toggleChineseTranslation)
                Button("最近阅读") { isShowingLibrary = true }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
            .buttonStyle(ReaderOutlinedButtonStyle())
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
        .background(ReaderTheme.paper(colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ReaderTheme.primary.opacity(0.12), lineWidth: 1)
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
        .background(ReaderTheme.paper(colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(ReaderTheme.primary.opacity(0.14), lineWidth: 1)
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
                        .buttonStyle(ReaderOutlinedButtonStyle())
                    }
                }

                if !readingSentences.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "hand.tap")
                            .foregroundStyle(ReaderTheme.primary)
                        Text("点按单词可标记 · 长按或右键查看词义 · 点句首播放按钮从该句朗读")
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
        let isMarked = highlightedTokens.contains(id)
        return HStack(alignment: .center, spacing: 2) {
            if isSentenceStart {
                Button {
                    readSentenceFromStart(at: wordIndex)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: max(9, fontSize * 0.42), weight: .bold))
                        .foregroundStyle(ReaderTheme.primary)
                        .frame(width: max(22, fontSize), height: max(22, fontSize))
                        .background(ReaderTheme.primary.opacity(colorScheme == .dark ? 0.28 : 0.12), in: Circle())
                }
                .buttonStyle(TokenButtonStyle())
                .accessibilityLabel("从本句开头朗读")
                .accessibilityHint("从第 \(wordIndex + 1) 个词开始播放，并同步进度")
            }

            if let word {
                Button {
                    toggleHighlight(id)
                } label: {
                    tokenLabel(token, isCurrentlySpoken: isCurrentlySpoken, hasBeenRead: hasBeenRead, isMarked: isMarked)
                }
                .buttonStyle(TokenButtonStyle())
                .fixedSize()
                .accessibilityLabel(word)
                .accessibilityHint("点按标记或取消标记。长按或打开菜单可查看词义。")
                .accessibilityValue(isCurrentlySpoken ? "正在朗读" : (isMarked ? "已标记" : "未标记"))
                .accessibilityAddTraits(isMarked ? .isSelected : AccessibilityTraits())
                .accessibilityAction(named: Text("查看词义")) {
                    showWordDetail(id: id, word: word)
                }
                .accessibilityAction(named: Text("朗读单词")) {
                    speakLookupWord(word)
                }
                .contextMenu {
                    Button("查看词义") { showWordDetail(id: id, word: word) }
                    Button("朗读单词") { speakLookupWord(word) }
                    if isSentenceStart {
                        Button("从本句开头朗读") { readSentenceFromStart(at: wordIndex) }
                    }
                    Button(isMarked ? "取消标记" : "标记单词") { toggleHighlight(id) }
                }
                .help("点按标记，长按或右键查看词义")
            } else {
                tokenLabel(token, isCurrentlySpoken: isCurrentlySpoken, hasBeenRead: hasBeenRead, isMarked: false)
                    .accessibilityHidden(token.display.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .fixedSize()
        .id("spoken-word-\(wordIndex)")
        .popover(item: wordSelectionBinding(for: id), arrowEdge: .bottom) { selection in
            WordDetailView(word: selection.word, accent: accent, style: .card, speak: {
                speakLookupWord(selection.word)
            }, onExpand: {
                let next = selection
                selectedWord = nil
                DispatchQueue.main.async {
                    expandedWord = next
                }
            })
        }
    }

    private func tokenLabel(_ token: ReadingToken, isCurrentlySpoken: Bool, hasBeenRead: Bool, isMarked: Bool) -> some View {
        Text(token.display)
            .font(.system(size: fontSize, design: fontStyle.design))
            .fontWeight(isCurrentlySpoken ? .bold : .regular)
            .foregroundStyle(hasBeenRead ? ReaderTheme.read(colorScheme) : Color.primary)
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(
                isCurrentlySpoken
                    ? ReaderTheme.currentWord(colorScheme)
                    : (isMarked ? ReaderTheme.markedWord(colorScheme) : Color.clear),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .scaleEffect(isCurrentlySpoken ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isCurrentlySpoken)
            .contentShape(Rectangle())
    }

    private func toggleHighlight(_ id: String) {
        if highlightedTokens.contains(id) {
            highlightedTokens.remove(id)
        } else {
            highlightedTokens.insert(id)
        }
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

    private var controls: some View {
        VStack(spacing: 8) {
            if audio.hasAudio {
                audioControls
                if usesTTSForAudio {
                    compactTextControls
                }
            } else if hasLoadedContent {
                compactTextControls
            }
            if hasLoadedContent {
                speechRateControl
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ReaderTheme.cardStroke(colorScheme), lineWidth: 1)
        }
        .shadow(color: ReaderTheme.primary.opacity(0.05), radius: 6, y: 2)
    }

    private var speechRateControl: some View {
        HStack(spacing: 8) {
            Text("语速")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Slider(value: $settings.speed, in: 0.18...0.68, step: 0.01)
                .accessibilityLabel("语速")
                .accessibilityValue(String(format: "%.2f 倍", speed / 0.45))
            Text(String(format: "%.2f×", speed / 0.45))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private var compactTextControls: some View {
        HStack(spacing: 12) {
            readingProgress
            ttsControls
        }
    }

    private var readingProgress: some View {
        let completedWords = min(
            max(0, speech.isSpeaking ? (activeSpokenWordIndex ?? -1) + 1 : Int(pendingReadingWordIndex.rounded())),
            wordCount
        )
        let maximumWordIndex = max(0, wordCount - 1)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("文章朗读进度", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(completedWords) / \(wordCount) 词")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if wordCount > 1 {
                Slider(
                    value: Binding(
                        get: {
                            if isScrubbingReadingProgress { return pendingReadingWordIndex }
                            if speech.isSpeaking {
                                return Double(min(maximumWordIndex, activeSpokenWordIndex ?? 0))
                            }
                            return min(Double(maximumWordIndex), pendingReadingWordIndex)
                        },
                        set: { pendingReadingWordIndex = $0 }
                    ),
                    in: 0...Double(maximumWordIndex),
                    step: 1,
                    onEditingChanged: { isEditing in
                        isScrubbingReadingProgress = isEditing
                        if isEditing {
                            pendingReadingWordIndex = Double(min(maximumWordIndex, activeSpokenWordIndex ?? 0))
                        } else if speech.isSpeaking {
                            seekTextReading(to: Int(pendingReadingWordIndex.rounded()))
                        }
                    }
                )
                .tint(.accentColor)
                .accessibilityValue("已定位到第 \(completedWords) 个词，共 \(wordCount) 个单词；拖动后从目标位置开始或继续朗读")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ReaderTheme.sunshine.opacity(colorScheme == .dark ? 0.24 : 0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var ttsControls: some View {
        HStack(spacing: 6) {
            Button {
                if speech.isSpeaking {
                    speech.stop()
                } else {
                    if audio.hasAudio { audio.pause() }
                    isEditingText = false
                    startTextReading()
                }
            } label: {
                Label(
                    speech.isSpeaking
                        ? (audio.hasAudio ? "停止 TTS 朗读" : "关闭阅读")
                        : (audio.hasAudio ? "开始 TTS 朗读" : "开始阅读"),
                    systemImage: speech.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
                    .frame(minWidth: 110)
            }
            .buttonStyle(ReaderFilledButtonStyle(color: speech.isSpeaking ? .red : ReaderTheme.primary))
            .disabled(!speech.isSpeaking && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                speech.togglePause()
            } label: {
                Label(speech.isPaused ? "继续" : "暂停", systemImage: speech.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(ReaderOutlinedButtonStyle())
            .disabled(!speech.isSpeaking)

        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(audio.fileName).font(.headline).lineLimit(1)
                        Text(audio.transcriptionStatus ?? "已识别音频文本")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAudioProgressVisible.toggle()
                    }
                }
                .help(isAudioProgressVisible ? "点击隐藏播放进度" : "点击显示播放进度")
            }

            Picker("朗读来源", selection: $usesTTSForAudio) {
                Text("原音频").tag(false)
                Text("TTS 朗读").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(audio.isTranscribing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if audio.isTranscribing {
                Text("识别完成后可选择 TTS 朗读；儿童模式只影响 TTS。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if childMode && !usesTTSForAudio {
                Text("当前播放原音频；切换到 TTS 朗读后儿童模式才会生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if audio.isTranscribing {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("识别中，音频可随时播放")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("停止识别") { cancelAudioTranscription() }
                        .accessibilityLabel("停止音频识别")
                }
            }

            if !usesTTSForAudio && isAudioProgressVisible {
                Slider(
                    value: Binding(
                        get: { audio.currentTime },
                        set: { audio.seek(to: $0) }
                    ),
                    in: 0...max(audio.duration, 0.01)
                )
                .tint(.accentColor)
                .disabled(!audio.canControlPlayback)
                .accessibilityHint(audio.loopLowerBound == nil ? "拖动调整播放位置" : "正在循环播放标记片段")

                if loopStart != nil || audio.loopLowerBound != nil {
                    audioLoopTrack
                }

                HStack {
                    Text(audio.formattedTime(audio.currentTime)).monospacedDigit()
                    Spacer()
                    Text(audio.formattedTime(audio.duration)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !usesTTSForAudio {
                HStack(spacing: 8) {
                    Image(systemName: "speedometer")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(value: $audioPlaybackRate, in: 0.1...4.0, step: 0.1)
                        .accessibilityLabel("音频播放倍率，范围 0.1 到 4")
                    Text(String(format: "%.1f×", audioPlaybackRate))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                        .accessibilityHidden(true)
                }

                HStack(spacing: 8) {
                    Button { audio.skip(by: -15) } label: {
                        Image(systemName: "gobackward.15")
                            .frame(minWidth: 28, minHeight: 22)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!audio.canControlPlayback)
                    .accessibilityLabel("后退 15 秒")

                    Button { audio.togglePlayback() } label: {
                        Label(audio.isPlaying ? "暂停音频" : "播放音频", systemImage: audio.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(ReaderFilledButtonStyle())
                    .disabled(!audio.canControlPlayback)

                    Button { audio.skip(by: 15) } label: {
                        Image(systemName: "goforward.15")
                            .frame(minWidth: 28, minHeight: 22)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!audio.canControlPlayback)
                    .accessibilityLabel("前进 15 秒")
                }

                HStack(spacing: 8) {
                    Button {
                        loopStart = audio.currentTime
                        loopHint = nil
                    } label: {
                        Label(loopATitle, systemImage: "a.circle")
                    }
                    .accessibilityLabel("设 A 点")
                    .accessibilityValue(loopAAccessibilityValue)

                    Button {
                        guard let start = loopStart else { return }
                        if audio.setLoop(start: start, end: audio.currentTime) {
                            loopStart = nil
                            loopHint = nil
                        } else {
                            loopHint = "B 点需要晚于 A 点至少 0.3 秒"
                        }
                    } label: {
                        Label(loopBTitle, systemImage: "b.circle")
                    }
                    .disabled(loopStart == nil)
                    .accessibilityLabel("设 B 点")
                    .accessibilityValue(audio.loopUpperBound.map { audio.formattedTime($0) } ?? "未设置")

                    if loopStart != nil || audio.loopLowerBound != nil {
                        Button {
                            loopStart = nil
                            loopHint = nil
                            audio.clearLoop()
                        } label: {
                            Label("清除", systemImage: "xmark.circle")
                        }
                        .accessibilityLabel("清除循环")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let loopHint {
                    Text(loopHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(ReaderTheme.paper(colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ReaderTheme.primary.opacity(0.12), lineWidth: 1)
        }
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

    private var selectedVoice: String? {
        selectedVoiceIdentifier.isEmpty ? nil : selectedVoiceIdentifier
    }

    private var loopATitle: String {
        if let start = loopStart {
            return "A \(audio.formattedTime(start))"
        }
        if let start = audio.loopLowerBound {
            return "A \(audio.formattedTime(start))"
        }
        return "设 A 点"
    }

    private var loopAAccessibilityValue: String {
        if let start = loopStart ?? audio.loopLowerBound {
            return audio.formattedTime(start)
        }
        return "未设置"
    }

    private var loopBTitle: String {
        if loopStart == nil, let end = audio.loopUpperBound {
            return "B \(audio.formattedTime(end))"
        }
        return "设 B 点"
    }

    private var audioLoopTrack: some View {
        Color.clear
            .frame(height: 22)
            .overlay {
                GeometryReader { geo in
                    let width = geo.size.width
                    let span = max(audio.duration, 0.01)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(height: 3)
                            .frame(maxHeight: .infinity, alignment: .center)
                        if loopStart == nil, let start = audio.loopLowerBound, let end = audio.loopUpperBound {
                            let origin = CGFloat(start / span) * width
                            let markWidth = CGFloat(max(0, end - start) / span) * width
                            Capsule()
                                .fill(ReaderTheme.primary.opacity(0.55))
                                .frame(width: max(2, markWidth), height: 3)
                                .frame(maxHeight: .infinity, alignment: .center)
                                .offset(x: origin)
                        }
                        if let start = loopStart ?? audio.loopLowerBound {
                            loopTick("A", x: CGFloat(start / span) * width, width: width)
                        }
                        if loopStart == nil, let end = audio.loopUpperBound {
                            loopTick("B", x: CGFloat(end / span) * width, width: width)
                        }
                    }
                }
            }
            .accessibilityHidden(true)
    }

    private func loopTick(_ title: String, x: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(ReaderTheme.primary)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ReaderTheme.primary)
        }
        .fixedSize()
        .offset(x: min(max(0, x - 6), max(0, width - 14)))
    }

    private func toggleEditing() {
        if isEditingText { text = EnglishTextFormatter.formatArticle(text) }
        isEditingText.toggle()
    }

    private func showWordDetail(id: String, word: String) {
        selectedWord = WordSelection(id: id, word: word)
    }

    private func speakLookupWord(_ word: String) {
        speech.speakWord(
            word,
            accent: accent,
            voiceIdentifier: selectedVoice,
            elevenLabsSettings: elevenLabsSettings,
            deepgramSettings: deepgramSettings
        )
    }

#if os(iOS)
    private var preferencesForm: some View {
        PreferencesView(
            localWhisperConfiguration: localWhisperConfiguration,
            elevenLabsSpeechConfiguration: elevenLabsSpeechConfiguration,
            accent: $settings.accent,
            selectedVoiceIdentifier: $settings.selectedVoiceIdentifier,
            speed: $settings.speed,
            childMode: $settings.childMode,
            wordPause: $settings.wordPause,
            fontStyle: $settings.fontStyle,
            fontSize: $settings.fontSize
        )
    }
#endif

    private func openPreferences() {
#if os(iOS)
        isShowingPreferences = true
#endif
    }

    private func showReaderColumnIfCompact() {
        if horizontalSizeClass == .compact {
            columnVisibility = .detailOnly
        }
    }

    private func openRecentArticle(_ item: RecentArticle) {
        text = item.text
        pendingReadingWordIndex = Double(item.position)
        isEditingText = false
        isShowingLibrary = false
        showReaderColumnIfCompact()
    }

    private var chineseTranslationBinding: Binding<Bool> {
        Binding(
            get: { showsChineseTranslation },
            set: { setChineseTranslation($0) }
        )
    }

    private func toggleChineseTranslation() {
        setChineseTranslation(!showsChineseTranslation)
    }

    private func setChineseTranslation(_ enabled: Bool) {
        guard enabled != showsChineseTranslation else { return }
        showsChineseTranslation = enabled
        if enabled, hasLoadedContent {
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

enum ReaderTheme {
    static let primary = Color(red: 0.29, green: 0.37, blue: 0.90)
    static let mint = Color(red: 0.55, green: 0.89, blue: 0.78)
    static let sunshine = Color(red: 1.00, green: 0.82, blue: 0.36)
    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.31, green: 0.40, blue: 0.96), Color(red: 0.60, green: 0.35, blue: 0.92)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func canvas(_ scheme: ColorScheme) -> LinearGradient {
        switch scheme {
        case .dark:
            return LinearGradient(
                colors: [Color(red: 0.07, green: 0.08, blue: 0.12), Color(red: 0.12, green: 0.10, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [Color(red: 0.96, green: 0.98, blue: 1.00), Color(red: 1.00, green: 0.97, blue: 0.90)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    static func settingsBackground(_ scheme: ColorScheme) -> LinearGradient {
        switch scheme {
        case .dark:
            return LinearGradient(
                colors: [Color(red: 0.10, green: 0.11, blue: 0.16), Color(red: 0.10, green: 0.13, blue: 0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
        default:
            return LinearGradient(
                colors: [Color(red: 0.94, green: 0.96, blue: 1.00), Color(red: 0.96, green: 1.00, blue: 0.96)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// Already-read word color. Light mode keeps the previous blue.
    static func read(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.62, green: 0.78, blue: 1.00) : .blue
    }

    /// Background behind the word currently being spoken.
    static func currentWord(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.35, green: 0.82, blue: 0.55).opacity(0.55)
            : Color.green.opacity(0.60)
    }

    /// Background for a manually marked word.
    static func markedWord(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.98, green: 0.80, blue: 0.30).opacity(0.45)
            : Color.yellow.opacity(0.65)
    }

    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.75)
    }

    static func paperStrong(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.78)
    }

    static func cardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.90)
    }
}

private struct OpenPreferencesButton: View {
    var fillsWidth = false
    var action: () -> Void = {}

    var body: some View {
        Group {
#if os(macOS)
            SettingsLink {
                label
            }
#else
            Button(action: action) {
                label
            }
#endif
        }
        .accessibilityHint("打开完整偏好设置")
    }

    private var label: some View {
        Label("偏好设置", systemImage: "gearshape")
            .frame(maxWidth: fillsWidth ? .infinity : nil)
    }
}

private struct ReadingSidebar: View {
    let recentArticles: [RecentArticle]
    let hasLoadedContent: Bool
    let showsReaderLink: Bool
    @Binding var childMode: Bool
    @Binding var showsChineseTranslation: Bool
    @Binding var accent: EnglishAccent
    let onSelect: (RecentArticle) -> Void
    let onShowReader: () -> Void
    let onOpenPreferences: () -> Void

    var body: some View {
        List {
            if showsReaderLink {
                Section {
                    Button(action: onShowReader) {
                        Label(hasLoadedContent ? "当前阅读" : "开始阅读", systemImage: "book")
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                if recentArticles.isEmpty {
                    Text("还没有最近阅读。导入或粘贴文章后会显示在这里。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentArticles) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).lineLimit(2)
                                Text("第 \(item.position + 1) 个词继续")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("从第 \(item.position + 1) 个词继续阅读")
                    }
                }
            } header: {
                Text("最近阅读")
            }

            Section {
                Toggle("儿童模式", isOn: $childMode)
                Toggle("中文翻译", isOn: $showsChineseTranslation)
                Picker("英语口音", selection: $accent) {
                    ForEach(EnglishAccent.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
            } header: {
                Text("快捷开关")
            } footer: {
                Text("语速在阅读区的播放控制里调节。完整的声音、字体和转写设置在偏好设置中。")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("阅读")
        .safeAreaInset(edge: .bottom) {
            OpenPreferencesButton(fillsWidth: true, action: onOpenPreferences)
                .buttonStyle(ReaderOutlinedButtonStyle())
                .padding(12)
        }
    }
}

/// Explicit button colors keep controls legible in both light and dark system appearances.
struct ReaderFilledButtonStyle: ButtonStyle {
    var color: Color = ReaderTheme.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize(horizontal: true, vertical: false)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Leaves the label's own colors alone, so read / current / mark highlights stay visible.
private struct TokenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct ReaderOutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize(horizontal: true, vertical: false)
            .fontWeight(.semibold)
            .foregroundStyle(ReaderTheme.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ReaderTheme.primary.opacity(configuration.isPressed ? 0.22 : 0.12), in: Capsule())
            .overlay {
                Capsule().stroke(ReaderTheme.primary.opacity(0.75), lineWidth: 1)
            }
            .contentShape(Capsule())
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
