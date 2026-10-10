import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct ExploreView: View {
    @ObservedObject var billing: BillingCenter
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(ExploreCatalog.categories, id: \.self) { category in
                    let endpoints = ExploreCatalog.endpoints.filter {
                        $0.category == category && (search.isEmpty || ($0.title + $0.summary).localizedCaseInsensitiveContains(search))
                    }
                    if !endpoints.isEmpty {
                        Section(category) {
                            ForEach(endpoints) { endpoint in
                                NavigationLink {
                                    ExploreQueryView(endpoint: endpoint, billing: billing)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(endpoint.title)
                                            .font(.headline)
                                        Text(endpoint.summary)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .padding(.vertical, 5)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("功能查询")
            .searchable(text: $search, prompt: "搜索作者、评论、热榜等功能")
            .overlay {
                if !search.isEmpty && !ExploreCatalog.endpoints.contains(where: { ($0.title + $0.summary).localizedCaseInsensitiveContains(search) }) {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }
}

@MainActor
private struct ExploreQueryView: View {
    let endpoint: ExploreEndpoint
    @ObservedObject var billing: BillingCenter
    @State private var values: [String: String]
    @State private var submittedValues: [String: String] = [:]
    @State private var result: ExploreResult?
    @State private var queryTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var copiedLabel: String?
    @State private var pageNumber = 1
    @State private var showingRawJSON = false
    @State private var exportingRawJSON = false
    @FocusState private var focusedField: String?

    init(endpoint: ExploreEndpoint, billing: BillingCenter) {
        self.endpoint = endpoint
        self.billing = billing
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: endpoint.fields.map { ($0.key, $0.defaultValue) }))
    }

    private var busy: Bool { queryTask != nil || billing.isWorking }
    private var nextValues: [String: String]? {
        guard let result else { return nil }
        return ExploreCatalog.nextValues(for: endpoint, result: result, currentValues: submittedValues)
    }

    var body: some View {
        Form {
            Section {
                Text(endpoint.summary)
                    .foregroundStyle(.secondary)
                if !billing.hasAPIKey {
                    Label("请先在设置中填写 API Key。", systemImage: "key")
                        .font(.subheadline)
                }
            }

            if !endpoint.fields.isEmpty {
                Section("查询条件") {
                    ForEach(endpoint.fields) { field in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 5) {
                                Text(field.label).font(.subheadline.weight(.medium))
                                if field.required {
                                    Text("必填").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            TextField(field.placeholder.isEmpty ? "请输入\(field.label)" : field.placeholder,
                                      text: Binding(get: { values[field.key] ?? field.defaultValue }, set: { values[field.key] = $0 }),
                                      axis: .vertical)
                                .lineLimit(1...4)
                                .keyboardType(field.inputKind == .integer ? .numberPad : .default)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: field.key)
                                .disabled(busy)
                            if !field.help.isEmpty {
                                Text(field.help).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section {
                Button {
                    execute(values, isNextPage: false)
                } label: {
                    Label(result == nil ? "查询" : "重新查询", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .disabled(busy || !billing.hasAPIKey)
                if queryTask != nil {
                    HStack {
                        ProgressView()
                        Text("正在处理…").foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { queryTask?.cancel() }
                    }
                    .font(.subheadline)
                }
            } footer: {
                Text("每次查询都会先核对价格；收费请求确认后才会发送。")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            if let result {
                resultSections(result)
            }
        }
        .navigationTitle(endpoint.title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { queryTask?.cancel() }
        .fileExporter(isPresented: $exportingRawJSON,
                      document: ExploreJSONDocument(data: result?.rawJSON ?? Data()),
                      contentType: .json,
                      defaultFilename: "抖取-\(endpoint.id)-第\(pageNumber)页") { outcome in
            if case .failure(let error) = outcome,
               (error as? CocoaError)?.code != .userCancelled {
                errorMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func resultSections(_ result: ExploreResult) -> some View {
        Section("查询结果 · 第 \(pageNumber) 页") {
            if result.summary.isEmpty && result.sections.isEmpty {
                ContentUnavailableView("暂无结果", systemImage: "doc.text.magnifyingglass", description: Text("可以调整查询条件后重试。"))
            } else {
                if !result.summary.isEmpty {
                    valuesView(Array(result.summary.prefix(8)))
                    if result.summary.count > 8 {
                        DisclosureGroup("更多结果信息") {
                            valuesView(Array(result.summary.dropFirst(8)))
                        }
                    }
                } else {
                    Text("本页共 \(result.sections.reduce(0) { $0 + $1.rows.count }) 项")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let copiedLabel {
                Label("已复制\(copiedLabel)", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(result.sections) { section in
            Section(section.title) {
                ForEach(section.rows) { row in
                    resultCard(row)
                }
            }
        }

        if let nextValues {
            Section {
                Button {
                    execute(nextValues, isNextPage: true)
                } label: {
                    Label("查询下一页", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .disabled(busy || !billing.hasAPIKey)
            } footer: {
                Text("沿用本次查询条件。下一页是一次新的请求，费用单独确认。")
            }
        } else if result.hasMore == false {
            Section {
                Text("已到最后一页").font(.subheadline).foregroundStyle(.secondary)
            }
        }

        Section {
            DisclosureGroup("查看原始 JSON", isExpanded: $showingRawJSON) {
                let raw = String(decoding: result.rawJSON, as: UTF8.self)
                Text(String(raw.prefix(24_000)))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                if raw.count > 24_000 {
                    Text("这里显示部分内容，导出可保存完整结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                exportingRawJSON = true
            } label: {
                Label("导出完整 JSON", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func resultCard(_ row: ExploreRow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let imageURL = row.imageURL {
                    AsyncImage(url: imageURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color(uiColor: .tertiarySystemFill)
                    }
                    .frame(width: 54, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(.headline).textSelection(.enabled)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if !row.values.isEmpty {
                valuesView(Array(row.values.prefix(6)))
                if row.values.count > 6 {
                    DisclosureGroup("更多信息") {
                        valuesView(Array(row.values.dropFirst(6)))
                    }
                    .font(.subheadline)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func valuesView(_ items: [ExploreValue]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.label).font(.caption).foregroundStyle(.secondary)
                        Text(item.value).font(.subheadline).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    if item.label.contains("ID") || item.label.contains("标识") || item.label.contains("抖音号") || item.label == "短号" {
                        Button {
                            UIPasteboard.general.string = item.value
                            copiedLabel = item.label
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("复制\(item.label)")
                    }
                }
            }
        }
    }

    private func execute(_ requestValues: [String: String], isNextPage: Bool) {
        guard !busy, billing.hasAPIKey else { return }
        focusedField = nil
        errorMessage = nil
        copiedLabel = nil
        do {
            let request = try ExploreCatalog.request(for: endpoint, values: requestValues)
            queryTask = Task {
                defer { queryTask = nil }
                do {
                    let data = try await billing.perform(request)
                    try Task.checkCancellation()
                    let decoded = try ExploreDecoder.decode(data, title: endpoint.title)
                    result = decoded
                    submittedValues = requestValues
                    pageNumber = isNextPage ? pageNumber + 1 : 1
                    showingRawJSON = false
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError),
                          (error as? URLError)?.code != .cancelled else { return }
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ExploreJSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
