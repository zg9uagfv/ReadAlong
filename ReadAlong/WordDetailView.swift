import SwiftUI

struct WordDetailView: View {
    enum Style {
        case card
        case full
    }

    let word: String
    let accent: EnglishAccent
    var style: Style = .card
    let speak: () -> Void
    var onExpand: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var definition: WordDefinition?
    @State private var errorMessage: String?
    @State private var reloadToken = 0

    var body: some View {
        Group {
            if style == .card {
                card
            } else {
                full
            }
        }
        .task(id: "\(word)#\(reloadToken)") {
            await load()
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(definition?.word ?? word)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    if let phonetic = definition?.phonetic {
                        Text(phonetic)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button(action: speak) {
                    Label("发音", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(ReaderFilledButtonStyle())
                .accessibilityLabel("朗读单词")
                .accessibilityHint("使用\(accent.rawValue)发音")
            }

            if let definition {
                firstSense(definition)
            } else if let errorMessage {
                failure(errorMessage)
            } else {
                ProgressView("正在查询 \(word)…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let onExpand {
                Button(action: onExpand) {
                    Label("更多", systemImage: "text.book.closed")
                }
                .buttonStyle(ReaderOutlinedButtonStyle())
                .accessibilityHint("打开完整释义、例句和中文")
            }
        }
        .padding(16)
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 380, alignment: .leading)
    }

    private var full: some View {
        Group {
            if let definition {
                fullContent(definition)
            } else if let errorMessage {
                failure(errorMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("正在查询 \(word)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(definition?.word ?? word)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func fullContent(_ definition: WordDefinition) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                wordHeader(definition)
                sectionTitle("英英释义")
                ForEach(definition.meanings) { meaning in
                    meaningView(meaning)
                }
                sectionTitle("英汉释义")
                Text(definition.chineseDefinition)
                    .font(.body)
                    .textSelection(.enabled)
                Label("来源：\(definition.sourceName)", systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func firstSense(_ definition: WordDefinition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let meaning = definition.meanings.first {
                Text(meaning.partOfSpeech)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ReaderTheme.primary)
                if let sense = meaning.definitions.first {
                    Text(sense)
                        .font(.body)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("查询失败", systemImage: "exclamationmark.magnifyingglass")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试", action: retry)
                .buttonStyle(ReaderOutlinedButtonStyle())
                .accessibilityLabel("重试查询")
        }
    }

    private func wordHeader(_ definition: WordDefinition) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(definition.word).font(.largeTitle.bold())
                Text(definition.phonetic).font(.title3).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: speak) {
                Label("发音", systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(ReaderFilledButtonStyle())
            .accessibilityLabel("朗读单词")
            .accessibilityHint("使用\(accent.rawValue)发音")
        }
    }

    private func meaningView(_ meaning: WordDefinition.Meaning) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(meaning.partOfSpeech).font(.headline).foregroundStyle(ReaderTheme.primary)
            ForEach(meaning.definitions.indices, id: \.self) { index in
                Text("\(index + 1). \(meaning.definitions[index])")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !meaning.examples.isEmpty {
                Text("例句")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
                ForEach(meaning.examples.indices, id: \.self) { index in
                    Text("• \(meaning.examples[index])")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title2.bold())
    }

    private func retry() {
        definition = nil
        errorMessage = nil
        reloadToken += 1
    }

    private func load() async {
        definition = nil
        errorMessage = nil
        do {
            var result = try await DictionaryService.shared.lookup(word)
            guard !Task.isCancelled else { return }
            definition = result
            guard style == .full else { return }
            result.chineseDefinition = await DictionaryService.shared.loadChineseDefinition(for: result)
            guard !Task.isCancelled else { return }
            definition = result
        } catch {
            guard !Task.isCancelled else { return }
            if let urlError = error as? URLError,
               urlError.code == .timedOut || urlError.code == .cannotConnectToHost || urlError.code == .notConnectedToInternet {
                errorMessage = "在线词典连接超时。当前词典服务位于境外，请检查网络后重试。"
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
