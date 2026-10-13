import SwiftUI

extension CloudSyncPhase {
    var symbol: String {
        switch self {
        case .upToDate: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .offline: return "wifi.slash"
        case .paused: return "pause.circle"
        case .conflict, .error: return "exclamationmark.icloud"
        case .authenticationRequired: return "lock.icloud"
        case .pending: return "icloud.and.arrow.up"
        case .notChecked: return "icloud"
        }
    }
    var tint: Color {
        switch self {
        case .upToDate: return .green
        case .syncing, .pending: return .blue
        case .offline, .conflict, .error, .authenticationRequired: return .orange
        case .paused, .notChecked: return .secondary
        }
    }
}

struct CloudSyncSummary: Equatable {
    let phase: CloudSyncPhase
    let text: String
    init(phases: [CloudSyncPhase], pending: Int, localUnsaved: Bool) {
        let priority: [CloudSyncPhase] = [.conflict, .authenticationRequired, .error, .offline, .paused, .syncing, .pending, .notChecked, .upToDate]
        phase = priority.first(where: phases.contains) ?? .notChecked
        let suffix = pending > 0 ? " · 待同步 \(pending) 项" : ""
        switch phase {
        case .conflict: text = "有冲突 · 需核对"
        case .authenticationRequired: text = "需要重新登录"
        case .error: text = "连接/同步失败" + suffix
        case .offline: text = "离线" + suffix
        case .paused: text = (phases.allSatisfy { $0 == .paused } ? "同步已暂停" : "部分同步暂停") + suffix
        case .syncing: text = "正在同步" + suffix
        case .pending: text = "待同步 \(pending) 项"
        case .notChecked: text = "尚未确认" + suffix
        case .upToDate: text = localUnsaved ? "等待本机保存" : "服务端已确认"
        }
    }
}

struct WorkspaceSyncFooter: View {
    @EnvironmentObject var workspace: CloudWorkspace
    @EnvironmentObject var account: CloudAccount
    @EnvironmentObject var store: OOSStore
    let openAccount: () -> Void
    var body: some View {
        Group {
            if workspace.matches(account: account), let organization = workspace.sync, let personal = workspace.personalSync {
                AccountSyncFooter(organization: organization, personal: personal, openAccount: openAccount)
            } else {
                Button(action: openAccount) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(workspace.ready ? "本机：\(store.saveMessage)" : "工作区正在加载", systemImage: "internaldrive")
                        Label(workspace.ready ? "云端：未登录 · 管理同步" : "查看账号与同步", systemImage: "icloud")
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).padding(14)
            }
        }
    }
}

private struct AccountSyncFooter: View {
    @ObservedObject var organization: CloudSync
    @ObservedObject var personal: CloudSync
    @EnvironmentObject var store: OOSStore
    @State private var showing = false
    let openAccount: () -> Void
    private var summary: CloudSyncSummary {
        CloudSyncSummary(phases: [organization.phase, personal.phase],
                         pending: organization.pendingCount + personal.pendingCount,
                         localUnsaved: store.hasUnsavedChanges)
    }
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("本机：\(store.saveMessage)", systemImage: store.hasUnsavedChanges ? "internaldrive" : "checkmark.circle")
                        .foregroundStyle(store.connected ? Color.secondary : Color.orange)
                    Label("云端：\(summary.text)", systemImage: summary.phase.symbol)
                        .foregroundStyle(summary.phase.tint)
                }.font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(12)
            .help("同步管理：服务端状态、立即同步、暂停/恢复与冲突核对")
            .accessibilityLabel("同步管理。本机：\(store.saveMessage)。云端：\(summary.text)")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                SyncQuickPanel(organization: organization, personal: personal) {
                    showing = false; openAccount()
                }.environmentObject(store)
            }
    }
}

private struct SyncQuickPanel: View {
    @ObservedObject var organization: CloudSync
    @ObservedObject var personal: CloudSync
    @EnvironmentObject var store: OOSStore
    let openAccount: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("同步管理").font(.headline)
                Spacer()
                Button("账号与组织…", action: openAccount).font(.caption)
            }
            Label("本机：\(store.saveMessage)", systemImage: "internaldrive")
                .font(.callout)
            if store.hasUnsavedChanges || !store.connected {
                Button("重试保存到本机") { Task { _ = await store.flush(); await store.refresh() } }.disabled(store.busy)
            }
            Divider()
            SyncScopeControls(sync: organization)
            Divider()
            SyncScopeControls(sync: personal)
            Divider()
            Text("断网仍可工作：修改先保存本机，联网后自动补传；网络失败会延迟重试，最长 5 分钟，也可手动立即重试。冲突不会静默覆盖，须核对后处理。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("组织任务共享给组织；私人任务只同步给本人。拼图及图片仅在本机，不上云。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(width: 390)
    }
}

private struct SyncScopeControls: View {
    @ObservedObject var sync: CloudSync
    @State private var reviewing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(sync.scope.title).font(.subheadline.bold())
                Spacer()
                if sync.busy { ProgressView().controlSize(.mini) }
                Label(sync.statusLabel, systemImage: sync.phase.symbol).foregroundStyle(sync.phase.tint).font(.caption)
            }
            if let date = sync.lastSyncedAt {
                Text("上次服务端确认：\(date.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("服务端尚未确认本机内容").font(.caption).foregroundStyle(.secondary)
            }
            if let next = sync.nextRetryAt, !sync.paused {
                Text("下次自动重试：\(next.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
            if let error = sync.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Button(sync.paused ? "恢复并同步" : "立即同步") {
                    Task { if sync.paused { await sync.resume() } else { await sync.retry() } }
                }.disabled(sync.busy || (!sync.paused && sync.hasConflict))
                if !sync.paused {
                    Button("暂停自动同步") { Task { await sync.pause() } }.disabled(sync.busy)
                }
                if sync.hasConflict {
                    Button("核对冲突…") { Task { await sync.reviewConflict(); reviewing = sync.conflict != nil } }.disabled(sync.busy)
                }
            }.controlSize(.small)
        }.sheet(isPresented: $reviewing) { CloudConflictReviewView(sync: sync) }
    }
}
