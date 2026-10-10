import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: DownloadModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var showingImporter = false
    @State private var showingRemovalConfirmation = false
    @State private var importing = false
    @State private var importStatus = ""
    @State private var cancelImport: (() -> Void)?
    @State private var feedback: String?
    @State private var configurationError: String?

    private var configurationBusy: Bool { model.busy || importing }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        model.hasAPIKey ? "API Key 已配置" : "尚未配置 API Key",
                        systemImage: model.hasAPIKey ? "checkmark.circle.fill" : "key"
                    )
                    .foregroundStyle(model.hasAPIKey ? Color.green : Color.secondary)

                    SecureField(model.hasAPIKey ? "填写新的 API Key 以替换" : "输入 API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()

                    Button(model.hasAPIKey ? "更新 API Key" : "保存 API Key") { savePastedConfiguration(apiKey) }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || configurationBusy)

                    HStack {
                        Label("粘贴并保存", systemImage: "doc.on.clipboard")
                        Spacer()
                        PasteButton(payloadType: String.self) { values in
                            savePastedConfiguration(values.joined(separator: "\n"))
                        }
                        .disabled(configurationBusy)
                    }
                } header: {
                    Text("解析服务")
                } footer: {
                    Text("可以复制 API Key 本身，也可以复制 TIKHUB_API_KEY=… 或整个配置文件的文字，然后点“粘贴”。内容会自动识别并保存，不会显示密钥。")
                }

                Section {
                    Button {
                        feedback = nil
                        configurationError = nil
                        showingImporter = true
                    } label: {
                        Label("导入配置文件（.txt / .env）", systemImage: "doc.badge.arrow.up")
                    }
                    .disabled(configurationBusy)

                    if importing {
                        HStack(alignment: .top, spacing: 10) {
                            ProgressView()
                            Text(importStatus).font(.subheadline)
                        }
                        Button("取消导入", role: .cancel) { cancelImport?() }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("选择 TikHub.env 或 TikHub.txt。导入时先复制到应用，再读取内容，无需修改文件名。")
                        Text("云盘文件会由系统先下载。若文件提供方不能交付文件，可以打开文件复制其中的文字，再使用上面的“粘贴并保存”。")
                    }
                }

                if let feedback {
                    Section {
                        Label(feedback, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    }
                }

                if let configurationError {
                    Section {
                        Label(configurationError, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                }

                if model.hasAPIKey {
                    Section {
                        Button("移除已保存的 API Key", role: .destructive) {
                            showingRemovalConfirmation = true
                        }
                        .disabled(configurationBusy)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.disabled(importing)
                }
            }
            .interactiveDismissDisabled(importing)
            .fullScreenCover(isPresented: $showingImporter) {
                ConfigurationDocumentPicker(
                    onSelected: { filename, cancel in
                        importing = true
                        cancelImport = cancel
                        importStatus = "已选中 \(filename)，正在读取配置…"
                        showingImporter = false
                    },
                    onResult: { result in
                        importing = false
                        cancelImport = nil
                        showingImporter = false
                        switch result {
                        case .success(let key):
                            performConfigurationChange(errorPrefix: "文件已读取，但未能保存密钥：") {
                                try model.setAPIKey(key)
                                apiKey = ""
                                feedback = "配置已导入，API Key 已保存。"
                            }
                        case .failure(let error):
                            feedback = nil
                            if error is CancellationError {
                                feedback = "已取消导入，原有配置未改变。"
                                configurationError = nil
                            } else {
                                configurationError = error.localizedDescription
                            }
                        }
                    },
                    onCancel: { showingImporter = false }
                )
                .ignoresSafeArea()
            }
            .confirmationDialog("移除 API Key？", isPresented: $showingRemovalConfirmation, titleVisibility: .visible) {
                Button("移除", role: .destructive) {
                    performConfigurationChange {
                        try model.removeAPIKey()
                        apiKey = ""
                        feedback = "API Key 已移除。"
                    }
                }
            } message: {
                Text("再次解析视频前，需要重新配置。")
            }
        }
    }

    private func savePastedConfiguration(_ text: String) {
        performConfigurationChange {
            let key = try ConfigurationFileReader.key(from: text)
            try model.setAPIKey(key)
            apiKey = ""
            feedback = "API Key 已保存。"
        }
    }

    private func performConfigurationChange(errorPrefix: String = "", _ operation: () throws -> Void) {
        feedback = nil
        configurationError = nil
        do {
            try operation()
        } catch {
            configurationError = errorPrefix + error.localizedDescription
        }
    }
}
