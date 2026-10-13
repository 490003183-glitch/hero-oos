import SwiftUI

struct CloudAccountView: View {
    @EnvironmentObject var account: CloudAccount
    @State private var mode = "login"
    @State private var organization = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var joiningOrganization = ""
    @State private var newOrganizationName = ""
    @State private var memberAction: MemberAction?
    private struct MemberAction: Identifiable {
        let member: CloudMember
        let status: String
        let role: String
        let title: String
        var id: String { member.id + status + role }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                privacy
                CloudWorkspaceStatusView()
                if let error = account.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
                if let message = account.message {
                    Label(message, systemImage: "info.circle").foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let session = account.session { signedIn(session) }
                else { authentication }
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .textFieldStyle(.roundedBorder)
        .task {
            if account.session != nil { await account.refreshAccount() }
            else if account.bootstrapAvailable { mode = "bootstrap" }
        }
        .onDisappear { password = ""; confirmation = "" }
        .onChange(of: account.session?.user.id) { _, _ in
            password = ""; confirmation = ""
            if account.session != nil { Task { await account.refreshAccount() } }
        }
        .sheet(item: $memberAction) { action in
            VStack(alignment: .leading, spacing: 18) {
                Text(action.title).font(.title2.bold())
                Text("账号：\(action.member.username)")
                Text(action.status == "suspended" ? "停用后该成员不能再访问本组织的云端数据。个人数据不会被删除。" : "此操作会更新该成员在本组织的申请状态或管理权限。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("取消") { memberAction = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("确认") {
                        memberAction = nil
                        Task { await account.updateMember(action.member, status: action.status, role: action.role) }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 400)
        }
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("账号与组织").font(.largeTitle.bold())
                Label(account.api.baseURL.absoluteString, systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if account.busy { ProgressView().controlSize(.small).padding(.top, 8) }
            Button { Task {
                if account.session == nil { await account.restoreSession() }
                else { await account.refreshAccount() }
            } } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(account.busy)
        }
    }
    private var privacy: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Label("非私人任务同步到组织，获准成员共同管理；私人任务只同步到本人云端；拼图画布和图片只留本机。", systemImage: "person.crop.circle.badge.checkmark")
                Text("旧工作区需要明确迁入。每个账号与组织的本机空间独立；私人任务随本人账号跨设备恢复；拼图不上传，换电脑需另行复制本机图片和画布。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("传输经过 HTTPS 加密；目前不是端到端加密，服务器管理员仍具有运维访问权。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
    }
    private var authentication: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("未登录 · 本地任务仍可正常使用").font(.headline)
            Picker("账号操作", selection: $mode) {
                Text("登录").tag("login")
                Text("注册申请").tag("register")
                if account.bootstrapAvailable { Text("设置首个管理员").tag("bootstrap") }
            }.pickerStyle(.segmented).frame(maxWidth: 560).disabled(account.busy)
                .onChange(of: mode) { _, _ in password = ""; confirmation = ""; account.error = nil; account.message = nil }
            GroupBox(mode == "bootstrap" ? "设置组织管理员" : (mode == "register" ? "注册后需管理员审批" : "登录组织账号")) {
                VStack(alignment: .leading, spacing: 14) {
                    if mode == "bootstrap" {
                        TextField("组织名", text: $organization).accessibilityLabel("组织名")
                        Text("请设置你自己的账号和密码。密码仅在此处输入，不需要发给任何人。")
                            .font(.callout).foregroundStyle(.secondary)
                    } else { TextField("组织名", text: $organization).accessibilityLabel("组织名") }
                    TextField("账号", text: $username).textContentType(.username).accessibilityLabel("账号")
                    SecureField("密码（12–128 个字符）", text: $password).textContentType(mode == "login" ? .password : .newPassword)
                        .accessibilityLabel("密码").onSubmit { if mode == "login" { submitAuthentication() } }
                    if mode != "login" {
                        SecureField("再次输入密码", text: $confirmation).textContentType(.newPassword).accessibilityLabel("确认密码")
                            .onSubmit { submitAuthentication() }
                    }
                    Text("账号支持 3–64 位字母、数字和 _ . @ -，首位为字母或数字。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button(mode == "bootstrap" ? "完成管理员设置" : (mode == "register" ? "提交注册申请" : "登录")) { submitAuthentication() }
                            .buttonStyle(.borderedProminent).disabled(username.isEmpty || password.isEmpty || organization.isEmpty)
                    }
                }.padding(10)
            }.frame(maxWidth: 560).disabled(account.busy)
        }
    }
    private func submitAuthentication() {
        guard !account.busy else { return }
        if mode != "login", password != confirmation { account.error = "两次输入的密码不一致。"; return }
        Task {
            let succeeded: Bool
            switch mode {
            case "bootstrap": succeeded = await account.bootstrapAdministrator(organization: organization, username: username, password: password, confirmation: confirmation)
            case "register": succeeded = await account.register(organization: organization, username: username, password: password)
            default: succeeded = await account.login(organization: organization, username: username, password: password)
            }
            if succeeded { password = ""; confirmation = "" }
        }
    }
    @ViewBuilder private func signedIn(_ session: CloudSession) -> some View {
        GroupBox("当前账号") {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.user.username).font(.title2.bold())
                    Text("\(session.organization.name) · \(roleTitle(session.organization.role))").foregroundStyle(.secondary)
                }
                Spacer()
                Button("退出账号") { Task { await account.logout() } }.disabled(account.busy)
            }.padding(10)
        }
        GroupBox("我的组织") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(session.memberships) { membership in
                    HStack {
                        Text(membership.name).font(.headline)
                        if membership.id == session.organization.id { Text("当前").font(.caption).foregroundStyle(.blue) }
                        Spacer()
                        Text("\(roleTitle(membership.role)) · \(statusTitle(membership.status))").foregroundStyle(.secondary)
                    }
                }
                Text("切换组织时，请先退出，再使用同一账号、密码和目标组织名登录。不同组织使用独立身份范围。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    TextField("输入想加入的组织名", text: $joiningOrganization).accessibilityLabel("申请加入的组织名")
                    Button("申请加入") { Task { if await account.joinOrganization(joiningOrganization) { joiningOrganization = "" } } }
                        .disabled(joiningOrganization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.disabled(account.busy)
            }.padding(10)
        }
        if session.organization.role == "owner" {
            GroupBox("组织设置") {
                HStack {
                    TextField("新的组织名称", text: $newOrganizationName)
                    Button("修改组织名") { Task { if await account.renameOrganization(newOrganizationName) { newOrganizationName = "" } } }
                        .disabled(newOrganizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(10).disabled(account.busy)
            }
        }
        if account.canManageMembers { members }
    }
    private var members: some View {
        GroupBox("成员与申请审批") {
            VStack(alignment: .leading, spacing: 12) {
                if account.members.isEmpty {
                    Text("暂无成员记录；可点击顶部刷新重新读取。").foregroundStyle(.secondary)
                }
                ForEach(account.members.sorted { ($0.status == "pending" ? 0 : 1, $0.username) < ($1.status == "pending" ? 0 : 1, $1.username) }) { member in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.username).font(.headline)
                            Text("\(roleTitle(member.role)) · \(statusTitle(member.status))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if member.userId != account.userID && member.role != "owner" {
                            if member.status == "pending" {
                                Button("通过") { Task { await account.updateMember(member, status: "approved", role: "member") } }
                                    .buttonStyle(.borderedProminent)
                                Button("拒绝") { memberAction = MemberAction(member: member, status: "rejected", role: "member", title: "拒绝此申请？") }
                            } else if member.status == "approved" {
                                if account.session?.organization.role == "owner" {
                                    Button(member.role == "admin" ? "改为成员" : "设为管理员") {
                                        memberAction = MemberAction(member: member, status: "approved", role: member.role == "admin" ? "member" : "admin", title: "修改成员权限？")
                                    }
                                }
                                Button("停用") { memberAction = MemberAction(member: member, status: "suspended", role: member.role, title: "停用此成员？") }
                            } else {
                                Button("批准加入") { Task { await account.updateMember(member, status: "approved", role: "member") } }
                            }
                        }
                    }.padding(.vertical, 5)
                    if member.id != account.members.last?.id { Divider() }
                }
            }.padding(10).disabled(account.busy)
        }
    }
    private func roleTitle(_ role: String) -> String {
        switch role { case "owner": return "组织所有者"; case "admin": return "管理员"; default: return "成员" }
    }
    private func statusTitle(_ status: String) -> String {
        switch status { case "approved": return "已加入"; case "pending": return "待审批"; case "rejected": return "未通过"; case "suspended": return "已停用"; default: return status }
    }
}
