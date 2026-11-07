import SwiftUI

@MainActor
struct AccountView: View {
    @ObservedObject var model: DownloadModel
    @ObservedObject var billing: BillingCenter

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            List {
                Section { balanceHeader }

                Section {
                    NavigationLink {
                        HistoryView(store: billing.history, accountID: billing.historyAccountID, billing: billing)
                    } label: {
                        Label("费用明细", systemImage: "list.bullet.rectangle.portrait")
                    }
                    NavigationLink {
                        SettingsView(model: model)
                    } label: {
                        LabeledContent {
                            Text(billing.hasAPIKey ? "已配置" : "未配置")
                        } label: {
                            Label("API Key", systemImage: "key")
                        }
                    }
                    Link(destination: URL(string: "https://user.tikhub.io")!) {
                        LabeledContent {
                            Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.tertiary)
                        } label: {
                            Label("TikHub 后台", systemImage: "safari")
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    Button {
                        Task { await model.cleanUpSavedPhotos() }
                    } label: {
                        LabeledContent {
                            Text("\(model.savedAssetCount) 项")
                        } label: {
                            Label("清理已保存的照片", systemImage: "trash")
                        }
                    }
                    .disabled(model.busy || model.savedAssetCount == 0)
                    if model.busy, !model.status.isEmpty {
                        Label(model.status, systemImage: "hourglass").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                    }
                } header: {
                    Text("相册")
                } footer: {
                    Text("只删除抖取保存到相册的项目，不影响其他照片。删除后会进入“最近删除”，30 天内可恢复。")
                }

                Section {
                    NavigationLink { BillingInfoView() } label: {
                        Label("计费说明", systemImage: "info.circle")
                    }
                } footer: {
                    Text("抖取 \(version) · 视频 / 图文 / 实况")
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
            .navigationTitle("我的")
            .toast($model.notice)
            .refreshable { await billing.refreshBalance(force: true) }
        }
    }

    private var balanceHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("账户余额").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if billing.refreshing {
                    ProgressView().controlSize(.small)
                } else if billing.hasAPIKey {
                    Button { Task { await billing.refreshBalance(force: true) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("刷新余额")
                }
            }
            if let account = billing.account {
                Text(Money.usd(account.balance))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                HStack {
                    if let credit = account.freeCredit {
                        Label("赠送 \(Money.usd(credit))", systemImage: "gift")
                    }
                    Spacer()
                    Text("更新于 \(account.updatedAt.formatted(date: .omitted, time: .shortened))")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(billing.hasAPIKey ? "正在读取…" : "未连接")
                    .font(.title2.bold()).foregroundStyle(.secondary)
            }
            if let error = billing.accountError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct BillingInfoView: View {
    var body: some View {
        List {
            row("先报价，后确认", "每次付费请求前核对实时价格。解析作品价格正常（不超过 $0.01）时自动发送；翻页、重新获取链接、获取原画等仍需你确认；查不到价格时不会执行。", "checkmark.shield")
            row("基础价与实际扣款", "确认页显示美元基础价。阶梯优惠和赠送额度可能降低实际扣款，以 TikHub 账单为准。请求发出后取消，不能撤回服务端可能发生的计费。", "dollarsign.circle")
            row("不重复收费的操作", "下载已获取的素材、切换已有画质、合成实况、保存相册和导出文件都不会再次调用付费接口。", "arrow.triangle.2.circlepath")
            row("余额刷新", "App 在前台时每 30 秒及每次查询后刷新余额，刷新前会确认余额接口仍为免费；网络失败时保留旧余额并提示。", "clock")
        }
        .navigationTitle("计费说明")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ text: String, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
    }
}
