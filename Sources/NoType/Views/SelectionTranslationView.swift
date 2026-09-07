import SwiftUI

struct SelectionTranslationView: View {
    @ObservedObject var model: SelectionTranslationModel
    @FocusState private var closeButtonFocused: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("简体中文", systemImage: "character.bubble")
                    .font(.headline)
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                    Text("翻译中…").foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorMessage = model.errorMessage {
                        Label {
                            Text(errorMessage).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    } else if !model.translatedText.isEmpty {
                        Text(model.translatedText)
                            .font(.system(size: 16))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                    } else {
                        Text("正在读取并翻译选中文字…")
                            .foregroundStyle(.secondary)
                    }

                    if !model.sourceText.isEmpty {
                        DisclosureGroup("原文") {
                            Text(model.sourceText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            HStack {
                Text("Option + Esc 关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.hasCopied ? "已复制" : "复制译文") {
                    model.copyTranslation()
                }
                .disabled(model.isLoading || model.translatedText.isEmpty || model.errorMessage != nil)
                Button("关闭", action: close)
                    .keyboardShortcut(.cancelAction)
                    .focused($closeButtonFocused)
            }
            .padding(16)
        }
        .frame(minWidth: 360, minHeight: 220)
        .defaultFocus($closeButtonFocused, true)
    }
}
