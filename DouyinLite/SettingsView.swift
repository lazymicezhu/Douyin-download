import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: DownloadModel
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
        Form {
            Section {
                Label(
                    model.hasAPIKey ? "已连接 TikHub" : "尚未配置",
                    systemImage: model.hasAPIKey ? "checkmark.seal.fill" : "key"
                )
                .foregroundStyle(model.hasAPIKey ? Color.green : Color.secondary)
                .font(.headline)
            }

            Section {
                HStack {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    Spacer()
                    PasteButton(payloadType: String.self) { values in
                        savePastedConfiguration(values.joined(separator: "\n"))
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .disabled(configurationBusy)
                }
                Button {
                    feedback = nil
                    configurationError = nil
                    showingImporter = true
                } label: {
                    Label("导入配置文件", systemImage: "doc.badge.arrow.up")
                }
                .disabled(configurationBusy)

                if importing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(importStatus).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { cancelImport?() }
                    }
                }
            } header: {
                Text("快速导入")
            } footer: {
                Text("支持 API Key 本身、TIKHUB_API_KEY=… 或整个 .env / .txt 文件内容，自动识别。")
            }

            Section {
                SecureField(model.hasAPIKey ? "输入新 Key 以替换" : "输入 API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .submitLabel(.done)
                    .onSubmit { savePastedConfiguration(apiKey) }
                Button(model.hasAPIKey ? "替换" : "保存") { savePastedConfiguration(apiKey) }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || configurationBusy)
            } header: {
                Text("手动输入")
            } footer: {
                Text("密钥仅保存在本机钥匙串中。")
            }

            if let feedback {
                Section {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                }
            }

            if let configurationError {
                Section {
                    Label(configurationError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
            }

            if model.hasAPIKey {
                Section {
                    Button("移除 API Key", role: .destructive) {
                        showingRemovalConfirmation = true
                    }
                    .disabled(configurationBusy)
                }
            }
        }
        .navigationTitle("API Key")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(importing)
        .navigationBarBackButtonHidden(importing)
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
