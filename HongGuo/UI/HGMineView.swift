import SwiftUI

/// 我的（官方同款）：头像 / 昵称 / 红果号 / 关注·粉丝·获赞 → 快捷入口 → 历史 / 收藏 / 点赞 / 预约 标签 + 封面网格
struct HGMineView: View {
    enum Shelf: String, CaseIterable { case history = "历史", favorites = "收藏", likes = "点赞", reserve = "预约" }
    enum Filter: String, CaseIterable { case all = "全部", comic = "漫剧", ten = "看10集以上" }
    @State private var library = HGLibrary.shared
    @State private var account: HGAccountStatus?
    @State private var info: HGAccountInfo?
    @State private var cloud: [HGCloudHistoryRow] = []
    @State private var cloudFavorites: [HGCloudFavorite] = []
    @State private var reserved: [HGSeries] = []
    @State private var cloudError: String?
    @State private var showLogin = false
    @State private var showSettings = false
    @State private var resume: HGPlayerRequest?
    @AppStorage("hg.mine.shelf") private var shelf: Shelf = .history
    @State private var filter: Filter = .all
    @State private var managing = false

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    quickRow
                    VStack(alignment: .leading, spacing: 12) {
                        shelfTabs
                        if shelf == .history { filterRow }
                        if let cloudError { Text(cloudError).font(.caption).foregroundStyle(HGTheme.textTertiary).padding(.horizontal, 16) }
                        grid(width: geo.size.width - 32)
                            .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 14)
                    .background(HGTheme.surface.opacity(0.55), in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous))
                    HGBrandFooter().padding(.horizontal, 16).padding(.bottom, 24)
                }
                .padding(.top, 8)
                .frame(width: geo.size.width)
            }
            .refreshable { await refreshAccount() }
        }
        .background(HGTheme.background)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .navigationTitle("我的")
        .task { await refreshAccount() }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await refreshAccount() } }) {
            HGLoginSheet { showLogin = false }.presentationDetents([.large])
        }
        .sheet(isPresented: $showSettings) { NavigationStack { HGMineSettings(signedIn: signedIn, onLogout: {
            Task { await logout() }
        }) }.presentationDetents([.large]) }
        .fullScreenCover(item: $resume) { HGPlayerScreen(request: $0) }
        .navigationDestination(item: $openDetail) { HGDetailView(series: $0) }
    }

    // MARK: 顶部：头像 / 昵称 / 红果号 / 数字

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                HGCachedImage(url: signedIn ? info?.avatar.flatMap(URL.init(string:)) : nil) {
                    Circle().fill(HGTheme.surfaceHigh).overlay(Image(systemName: "person.fill").font(.title).foregroundStyle(HGTheme.textTertiary))
                }
                .frame(width: 60, height: 60).clipShape(Circle())
                VStack(alignment: .leading, spacing: 6) {
                    if signedIn {
                        Text(info?.name ?? account?.account?.nickname ?? "红果用户").font(.headline).foregroundStyle(HGTheme.textPrimary).lineLimit(1)
                        if let uid = info?.uid ?? account?.account?.id {
                            Button { UIPasteboard.general.string = uid } label: {
                                HStack(spacing: 4) {
                                    Text("红果号：\(uid)").font(.caption).foregroundStyle(HGTheme.textTertiary)
                                    Image(systemName: "doc.on.doc").font(.caption2).foregroundStyle(HGTheme.textTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button { showLogin = true } label: {
                            Text("登录红果账号").font(.headline).foregroundStyle(HGTheme.textPrimary)
                        }
                        .accessibilityIdentifier("hg.mine.login")
                        Text("手机号登录后同步推荐、观看记录、收藏、预约").font(.caption).foregroundStyle(HGTheme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                // 2026-11-26 老板：扫一扫放到「我的」右上，不用钻进设置
                Button { HGRootRouter.shared.scan() } label: {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 22, weight: .regular))
                        .foregroundStyle(HGTheme.textPrimary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("扫一扫")
                .accessibilityIdentifier("hg.mine.scan")
            }
            if signedIn {
                HStack(alignment: .bottom, spacing: 22) {
                    stat(info?.follows ?? 0, "关注"); stat(info?.fans ?? 0, "粉丝"); stat(info?.likes ?? 0, "获赞")
                    Spacer()
                    if let m = info?.watchMinutes, m > 0 {
                        Text("累计观看 \(m >= 60 ? "\(m / 60)小时" : "\(m)分钟")").font(.caption).foregroundStyle(HGTheme.textTertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func stat(_ n: Int, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(n >= 10_000 ? String(format: "%.1fw", Double(n) / 1e4) : "\(n)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(HGTheme.textPrimary)
            Text(title).font(.caption2).foregroundStyle(HGTheme.textSecondary)
        }
    }

    // MARK: 快捷入口（我们能接的：追剧 / 预约 / 储存 / 设置）

    private var quickRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                quick("追剧", sub: "\(mergedFavorites.count) 部") { shelf = .favorites }
                quick("预约", sub: signedIn ? "\(reserved.filter { $0.upcoming == true }.count) 部待上线" : "登录后同步") { shelf = .reserve }
                NavigationLink { DYStorageScreen() } label: { quickLabel("储存", sub: "清理缓存") }.buttonStyle(.plain)
                    .accessibilityIdentifier("hg.mine.storage")
                quick("设置", sub: "主题 / 缓存 / 更新") { showSettings = true }
                    .accessibilityIdentifier("hg.mine.settings")
            }
            .padding(.horizontal, 16)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // 横向滚动视图默认把内容画进安全区（右侧主菜单下面）：裁在自己的宽度里
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private func quick(_ t: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { quickLabel(t, sub: sub) }.buttonStyle(.plain).accessibilityIdentifier("hg.mine.quick.\(t)")
    }

    private func quickLabel(_ t: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(HGTheme.textPrimary)
            Text(sub).font(.caption2).foregroundStyle(HGTheme.textSecondary).lineLimit(1)
        }
        .frame(width: 86, height: 50, alignment: .leading).padding(.leading, 12)
        .background(HGTheme.surface, in: RoundedRectangle(cornerRadius: HGTheme.radius + 2, style: .continuous))
    }

    // MARK: 历史 / 收藏 / 点赞 / 预约

    private var shelfTabs: some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            ForEach(Shelf.allCases, id: \.self) { t in
                Button { shelf = t; managing = false } label: {
                    Text(t.rawValue).font(t == shelf ? .headline : .subheadline)
                        .foregroundStyle(t == shelf ? HGTheme.textPrimary : HGTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hg.mine.tab.\(t.rawValue)")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases, id: \.self) { f in
                let on = f == filter
                Button { filter = f } label: {
                    Text(f.rawValue).font(.caption).padding(.horizontal, 12).frame(height: 28)
                        .background(on ? HGTheme.accent.opacity(0.2) : HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall + 2, style: .continuous))
                        .foregroundStyle(on ? HGTheme.accent : HGTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(managing ? "完成" : "管理") { managing.toggle() }.font(.caption).foregroundStyle(HGTheme.textPrimary)
                .accessibilityIdentifier("hg.mine.manage")
        }
        .padding(.horizontal, 16)
    }

    private struct Cell: Identifiable { let series: HGSeries; let sub: String?; let history: HGCloudHistoryRow?; var id: String { series.id } }

    private var cells: [Cell] {
        switch shelf {
        case .history:
            return mergedHistory.filter { r in
                switch filter {
                case .all: true
                case .comic: (r.series.tags ?? []).contains("漫剧") || r.series_title.contains("漫")
                case .ten: r.vid_index >= 10
                }
            }.map { Cell(series: $0.series, sub: "\(max(1, $0.vid_index))集/\($0.total.map(String.init) ?? "?")集", history: $0) }
        case .favorites:
            return mergedFavorites.map { Cell(series: $0, sub: $0.episode_count.map { "共\($0)集" }, history: nil) }
        case .likes:
            return likedSeries.map { Cell(series: $0, sub: $0.episode_count.map { "共\($0)集" }, history: nil) }
        case .reserve:
            return reserved.map { Cell(series: $0, sub: $0.heat ?? ($0.upcoming == true ? "待上线" : "已上线"), history: nil) }
        }
    }

    /// 点过赞的剧（本机记录；红果账号的点赞列表没有公开接口）
    private var likedSeries: [HGSeries] { library.likedSeries }

    @ViewBuilder private func grid(width: CGFloat) -> some View {
        let list = cells
        if list.isEmpty {
            Text(emptyText).font(.footnote).foregroundStyle(HGTheme.textTertiary).frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            // 封面宽约 110（官方外屏一排 3 个），列数按宽度自适应
            let n = max(3, Int((width + 10) / 120))
            let w = (width - CGFloat(n - 1) * 10) / CGFloat(n)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: 10, alignment: .top), count: n), spacing: 16) {
                ForEach(list) { c in
                    Button { open(c) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Color.clear.aspectRatio(3 / 4, contentMode: .fit)
                                .overlay { HGCoverFill(url: c.series.coverURL) }
                                .overlay(alignment: .topTrailing) {
                                    if let b = c.series.badge ?? (c.series.upcoming == true ? "待上线" : nil) {
                                        Text(b).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(.black.opacity(0.5), in: UnevenRoundedRectangle(bottomLeadingRadius: 6, style: .continuous))
                                    }
                                }
                                .overlay(alignment: .topLeading) {
                                    if managing { Image(systemName: "minus.circle.fill").font(.title3).foregroundStyle(.white, HGTheme.accent).padding(4) }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
                            Text(c.series.series_title).font(.footnote).foregroundStyle(HGTheme.textPrimary).lineLimit(1)
                            if let sub = c.sub { Text(sub).font(.caption2).foregroundStyle(HGTheme.textTertiary).lineLimit(1) }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("hg.mine.cell")
                }
            }
            .accessibilityIdentifier(shelf == .history ? "hg.shelf.history" : "hg.shelf.\(shelf)")
        }
    }

    private var emptyText: String {
        switch shelf {
        case .history: "还没有观看记录"
        case .favorites: "还没有收藏"
        case .likes: "还没有点赞"
        case .reserve: signedIn ? "还没有预约" : "登录红果账号后显示预约"
        }
    }

    @State private var openDetail: HGSeries?

    private func open(_ c: Cell) {
        if managing {
            switch shelf {
            case .history: library.removeHistory(c.id); cloud.removeAll { $0.series_id == c.id }
            case .favorites: if library.isFavorite(c.id) { library.toggleFavorite(c.series) }
            default: break
            }
            return
        }
        if let h = c.history { Task { await play(h) } } else { openDetail = c.series }
    }

    private var signedIn: Bool { account?.signedIn == true }

    /// 本机记录 + 云端记录：同一部取最后看的那条（本机记录转成同一种行，episode_id 为空 = 按集序号定位）
    private var mergedHistory: [HGCloudHistoryRow] {
        let local = library.history.map { p in
            HGCloudHistoryRow(series_id: p.series.id, series_title: p.series.series_title, cover: p.series.cover,
                              episode_id: "", vid_index: p.episodeIndex + 1, currentTime: p.position,
                              total: p.series.episode_count, updatedAt: p.updatedAt.timeIntervalSince1970 * 1000)
        }
        var best: [String: HGCloudHistoryRow] = [:]
        for r in cloud + local {
            if let old = best[r.series_id], (old.updatedAt ?? 0) >= (r.updatedAt ?? 0) {
                // 封面 / 集数互相补
                if (old.cover ?? "").isEmpty, let c = r.cover, !c.isEmpty { best[r.series_id] = old.with(cover: c) }
                continue
            }
            var r = r
            if (r.cover ?? "").isEmpty, let c = best[r.series_id]?.cover { r = r.with(cover: c) }
            best[r.series_id] = r
        }
        return best.values.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    /// 红果 App 收藏在前（按收藏时间），再接本机收藏里云端没有的
    private var mergedFavorites: [HGSeries] {
        var seen = Set<String>()
        return (cloudFavorites.map(\.series) + library.favorites).filter { seen.insert($0.id).inserted }
    }

    private func row(_ s: HGSeries, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            HGCover(url: s.coverURL).frame(width: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.series_title).foregroundStyle(HGTheme.textPrimary).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(HGTheme.textSecondary) }
            }
        }
    }

    @State private var refreshGen = 0

    private func logout() async {
        refreshGen += 1
        account = HGAccountStatus(signedIn: false, account: nil)
        info = nil; cloud = []; cloudFavorites = []; reserved = []; cloudError = nil
        library.switchAccount(nil)
        showSettings = false
        do { try await HGAPI.logout() } catch { cloudError = "退出失败：\(error.localizedDescription)" }
        await refreshAccount()
    }

    private func refreshAccount() async {
        refreshGen += 1
        let g = refreshGen
        #if DEBUG
        // 测试：假装已登录、云端有 N 条记录（看排版用，不连红果账号）
        if let n = Int(ProcessInfo.processInfo.environment["HG_DEMO_CLOUD"] ?? ""),
           let page = try? await HGAPI.browse(.hot, page: 1) {
            account = HGAccountStatus(signedIn: true, account: HGAccountProfile(id: "demo", nickname: "用户 演示"))
            let now = Date().timeIntervalSince1970 * 1000
            cloud = page.results.prefix(n).enumerated().map { i, s in
                HGCloudHistoryRow(series_id: s.series_id, series_title: s.series_title, cover: s.cover,
                                  episode_id: "", vid_index: i % 9 + 1, currentTime: 0, total: s.episode_count,
                                  updatedAt: now - Double(i) * 3_600_000 - 60_000)
            }
            cloudFavorites = page.results.suffix(4).map { HGCloudFavorite(series_id: $0.series_id, series_title: $0.series_title, cover: $0.cover, episode_count: $0.episode_count) }
            return
        }
        #endif
        let st = try? await HGAPI.accountStatus()
        guard g == refreshGen else { return }
        account = st
        guard account?.signedIn == true else { cloud = []; cloudFavorites = []; reserved = []; info = nil; return }
        // Result(catching:) 只接受同步闭包，async 闭包须用立即执行的 async 闭包包一层
        async let h: Result<[HGCloudHistoryRow], Error> = {
            do { return .success(try await HGAPI.cloudHistoryAll()) }
            catch { return .failure(error) }
        }()
        async let f: Result<[HGCloudFavorite], Error> = {
            do { return .success(try await HGAPI.cloudFavorites()) }
            catch { return .failure(error) }
        }()
        async let i = try? HGAPI.accountInfo()
        async let r = try? HGAPI.reservations()
        let (iv, rv, hv, fv) = (await i, await r, await h, await f)
        // 中途退出 / 又刷了一次：这批结果作废
        guard g == refreshGen, account?.signedIn == true else { return }
        info = iv
        reserved = rv ?? []
        var errors: [String] = []
        switch hv {
        case .success(let rows): cloud = rows
        case .failure(let e): errors.append("观看记录读取失败：\(e.localizedDescription)")
        }
        switch fv {
        case .success(let rows): cloudFavorites = rows
        case .failure(let e): errors.append("收藏读取失败：\(e.localizedDescription)")
        }
        cloudError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// 云端记录续播：按分集编号定位，找不到就从记录的集序号开始，不把云端进度套到第 1 集。
    private func play(_ r: HGCloudHistoryRow) async {
        guard let d = try? await HGAPI.detail(r.series_id) else { return }
        let byVid = r.episode_id.isEmpty ? nil : d.episodes.firstIndex { $0.vid == r.episode_id }
        let idx = byVid ?? (r.vid_index > 0 && !d.episodes.isEmpty ? min(d.episodes.count - 1, r.vid_index - 1) : nil)
        guard let idx else { return }
        var s = r.series; s.episode_count = d.episodes.count
        if (s.cover ?? "").isEmpty { s.cover = d.cover }
        // 云端记录：分集编号对上才续进度；本机记录（没有分集编号）按集序号续
        let exact = byVid != nil || (r.episode_id.isEmpty && idx == r.vid_index - 1)
        resume = HGPlayerRequest(series: s, episodes: d.episodes, index: idx, startAt: exact ? r.currentTime : 0)
    }
}

/// 登录红果账号：手机号 + 验证码（默认，照绿果TV）/ 另一台手机扫码。
/// 红果 App「扫一扫」只认相机实时扫，不认相册截图 → 扫码只适合拿另一台手机对着屏幕扫。
struct HGLoginSheet: View {
    enum Mode: String, CaseIterable { case phone = "手机号登录", qr = "扫码登录" }
    let done: () -> Void
    @State private var mode: Mode = .phone

    var body: some View {
        VStack(spacing: 14) {
            Picker("登录方式", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("hg.login.mode")
            switch mode {
            case .phone: HGPhoneLogin(done: done)
            case .qr: HGQRLoginPane(done: done)
            }
            Spacer(minLength: 0)
            Text("登录后推荐按你的红果账号来，并同步观看记录、收藏、预约（只读，不会改动账号）。")
                .font(.caption2).foregroundStyle(HGTheme.textTertiary).multilineTextAlignment(.center)
        }
        .padding(20)
    }
}

/// 手机号 + 验证码；红果风控时要求「用这个手机号发一条短信」做二次验证
struct HGPhoneLogin: View {
    let done: () -> Void
    @State private var phone = ""
    @State private var code = ""
    @State private var sentAt: Date?
    @State private var busy = false
    @State private var message: String?
    @State private var mfa: HGPhoneStep?
    @State private var polling: Task<Void, Never>?
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @Environment(\.openURL) private var openURL

    private var digits: String { phone.filter(\.isNumber) }
    private var cooldown: Int { sentAt.map { max(0, 60 - Int(now.timeIntervalSince($0))) } ?? 0 }

    var body: some View {
        VStack(spacing: 12) {
            if let mfa, let number = mfa.number, let content = mfa.content {
                mfaPane(number: number, content: content)
            } else {
                HStack(spacing: 8) {
                    Text("+86").foregroundStyle(HGTheme.textSecondary)
                    TextField("手机号", text: $phone)
                        .keyboardType(.numberPad).textContentType(.telephoneNumber)
                        .accessibilityIdentifier("hg.login.phone")
                }
                .padding(.horizontal, 14).frame(height: 46)
                .background(HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
                HStack(spacing: 8) {
                    TextField("验证码", text: $code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .accessibilityIdentifier("hg.login.code")
                    Button(cooldown > 0 ? "\(cooldown) 秒后重发" : (sentAt == nil ? "获取验证码" : "重新获取")) { Task { await send() } }
                        .font(.subheadline).disabled(busy || cooldown > 0 || digits.count != 11)
                        .accessibilityIdentifier("hg.login.send")
                }
                .padding(.horizontal, 14).frame(height: 46)
                .background(HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
                Button { Task { await login() } } label: {
                    Group { if busy { ProgressView() } else { Text("登录") } }
                        .font(.headline).frame(maxWidth: .infinity).frame(height: 46)
                }
                .buttonStyle(.borderedProminent).tint(HGTheme.accent)
                .disabled(busy || sentAt == nil || code.count < 4)
                .accessibilityIdentifier("hg.login.submit")
                Text("验证码由红果发到你的手机，GuoDuo 只转交给红果登录，不保存手机号。")
                    .font(.caption2).foregroundStyle(HGTheme.textTertiary).multilineTextAlignment(.center)
            }
            if let message { Text(message).font(.footnote).foregroundStyle(HGTheme.textSecondary).multilineTextAlignment(.center) }
        }
        .onReceive(tick) { now = $0 }
        .onDisappear { polling?.cancel(); Task { await HGAPI.phoneCancel() } }
    }

    private func mfaPane(number: String, content: String) -> some View {
        VStack(spacing: 10) {
            Text("红果要求短信验证").font(.headline)
            Text("用 +86 \(digits.suffix(4).isEmpty ? "" : "尾号 \(digits.suffix(4)) ")的手机，发送下面这条短信。发出后这里会自动登录。")
                .font(.footnote).foregroundStyle(HGTheme.textSecondary).multilineTextAlignment(.center)
            VStack(spacing: 4) {
                Text("发送到").font(.caption).foregroundStyle(HGTheme.textTertiary)
                Text(number).font(.title3.monospacedDigit().weight(.semibold)).textSelection(.enabled)
                Text("短信内容").font(.caption).foregroundStyle(HGTheme.textTertiary).padding(.top, 4)
                Text(content).font(.title3.monospacedDigit().weight(.semibold)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity).padding(12)
            .background(HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
            Button {
                let body = content.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? content
                if let url = URL(string: "sms:\(number.replacingOccurrences(of: " ", with: ""))&body=\(body)") { openURL(url) }
            } label: { Text("去发短信").font(.headline).frame(maxWidth: .infinity).frame(height: 46) }
                .buttonStyle(.borderedProminent).tint(HGTheme.accent)
                .accessibilityIdentifier("hg.login.sms")
            Button("已发送，立即验证") { Task { await verifyOnce() } }.font(.subheadline)
            Button("换个号码 / 重新获取验证码") { polling?.cancel(); mfa = nil; code = ""; sentAt = nil; message = nil }
                .font(.footnote).foregroundStyle(HGTheme.textSecondary)
        }
    }

    private func send() async {
        busy = true; message = nil
        defer { busy = false }
        do { try await HGAPI.phoneSend(digits); sentAt = Date(); now = Date(); message = "验证码已发送" }
        catch { message = error.localizedDescription }
    }

    private func login() async {
        busy = true; message = nil
        defer { busy = false }
        do { handle(try await HGAPI.phoneLogin(code.filter(\.isNumber))) }
        catch { message = error.localizedDescription }
    }

    private func handle(_ step: HGPhoneStep) {
        switch step.state {
        case "ok": message = "登录成功"; done()
        case "mfa":
            mfa = step; message = nil
            polling?.cancel()
            // 发完短信服务端要几秒才收到：每 4 秒问一次，最多 3 分钟
            polling = Task {
                for _ in 0..<45 {
                    try? await Task.sleep(for: .seconds(4))
                    if Task.isCancelled { return }
                    guard let s = try? await HGAPI.phoneVerify() else { continue }
                    if s.state != "pending" { handle(s); return }
                }
            }
        case "pending": message = "还没收到你发的短信，发出后稍等几秒"
        default: message = "登录已取消，请重试"
        }
    }

    private func verifyOnce() async {
        do { handle(try await HGAPI.phoneVerify()) } catch { message = error.localizedDescription }
    }
}

/// 扫码：红果「扫一扫」只认相机实时扫，截图/相册里的码扫不了 → 用另一台手机对着本屏扫
struct HGQRLoginPane: View {
    let done: () -> Void
    @State private var qr: HGQRLogin?
    @State private var image: UIImage?
    @State private var message = "正在获取二维码…"
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: HGTheme.radius).fill(.white).frame(width: 200, height: 200)
                if let image { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 184, height: 184) }
                else { ProgressView().tint(.black) }
            }
            Text(message).font(.footnote).foregroundStyle(HGTheme.textSecondary).multilineTextAlignment(.center)
            Text("用另一台已登录红果的手机，打开红果 App「我的 → 右上角扫一扫」，对准这个二维码扫描并确认。\n红果不支持识别截图或相册里的二维码；只有这一台手机时请用「手机号登录」。")
                .font(.caption2).foregroundStyle(HGTheme.textTertiary).multilineTextAlignment(.center)
            Button("刷新二维码") { start() }.font(.footnote)
        }
        .onAppear { start() }
        .onDisappear { task?.cancel(); if let id = qr?.loginId { Task { await HGAPI.cancelLogin(id) } } }
    }

    private func start() {
        task?.cancel()
        image = nil; message = "正在获取二维码…"
        task = Task {
            do {
                let q = try await HGAPI.startLogin()
                qr = q
                if let b64 = q.image.split(separator: ",").last, let data = Data(base64Encoded: String(b64)) { image = UIImage(data: data) }
                message = "等待另一台手机扫码…"
                let deadline = Date().addingTimeInterval(TimeInterval(max(30, q.expiresIn)))
                while !Task.isCancelled, Date() < deadline {
                    try await Task.sleep(for: .seconds(2))
                    let p = try await HGAPI.pollLogin(q.loginId)
                    if p.signedIn == true || p.status == "signed-in" { message = "登录成功"; done(); return }
                    switch p.status {
                    case "expired": message = "二维码已过期，点刷新"; return
                    case "cancelled": message = "已取消，点刷新重试"; return
                    default: break
                    }
                }
                if !Task.isCancelled { message = "二维码已过期，点刷新" }
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }
}


/// 一排横滑卡片（前 8 部）+ 右上角「全部 N」
struct HGShelfSection<Destination: View>: View {
    let title: String
    let empty: String
    let id: String
    let items: [(HGSeries, String?)]
    /// 给了就点卡片回调（如云端记录直接续播），不给就推详情页
    var tap: ((HGSeries) -> Void)? = nil
    @ViewBuilder let all: () -> Destination
    private static var limit: Int { 8 }

    var body: some View {
        Section {
            if items.isEmpty {
                Text(empty).foregroundStyle(HGTheme.textTertiary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items.prefix(Self.limit), id: \.0.id) { s, sub in
                            if let tap {
                                Button { tap(s) } label: { HGSeriesCard(series: s, subtitle: sub).frame(width: 96) }
                                    .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: s) { HGSeriesCard(series: s, subtitle: sub).frame(width: 96) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("hg.shelf.\(id)")
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if !items.isEmpty {
                    NavigationLink { all() } label: {
                        HStack(spacing: 2) {
                            Text("全部 \(items.count)")
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        }
                        .font(.footnote)
                        .foregroundStyle(HGTheme.textSecondary)
                    }
                    .accessibilityIdentifier("hg.shelf.\(id).all")
                }
            }
            .textCase(nil)
        }
        .listRowBackground(Color.clear)
    }
}

/// 「全部」页：完整网格，长按删除 / 取消收藏
struct HGSeriesListScreen: View {
    enum Kind { case history, favorites }
    let title: String
    let kind: Kind
    @State private var library = HGLibrary.shared
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                switch kind {
                case .history:
                    ForEach(library.history, id: \.series.id) { p in
                        NavigationLink(value: p.series) { HGSeriesCard(series: p.series, subtitle: "看到第 \(p.episodeIndex + 1) 集") }
                            .buttonStyle(.plain)
                            .contextMenu { Button("删除记录", systemImage: "trash", role: .destructive) { library.removeHistory(p.series.id) } }
                    }
                case .favorites:
                    ForEach(library.favorites) { s in
                        NavigationLink(value: s) { HGSeriesCard(series: s, subtitle: s.episode_count.map { "共 \($0) 集" }) }
                            .buttonStyle(.plain)
                            .contextMenu { Button("取消收藏", systemImage: "heart.slash", role: .destructive) { library.toggleFavorite(s) } }
                    }
                }
            }
            .padding(16)
        }
        .background(HGTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 「我的」最底下：logo、名字、一句介绍、仓库链接
struct HGBrandFooter: View {
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(spacing: 10) {
            Image("AppLogo").resizable().scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .accessibilityHidden(true)
            Text("GuoDuo").font(.headline).foregroundStyle(HGTheme.textPrimary)
            Text("原生 SwiftUI 的红果短剧客户端，适配 iPhone Duo 折叠屏、iPad 与普通 iPhone。开源免费，非官方。")
                .font(.caption).foregroundStyle(HGTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button { openURL(HGUpdateChecker.repoURL) } label: {
                Text("github.com/\(HGUpdateChecker.repo)").font(.caption.monospaced())
            }
            .tint(HGTheme.accent)
            .accessibilityIdentifier("hg.footer.repo")
            Text("片源来自红果 / 西饭 / 河马公开接口，接口变化时可能失效。仅供个人学习使用。")
                .font(.caption2).foregroundStyle(HGTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hg.footer")
    }
}


/// 红果 App 云端观看记录「全部」页：网格，点了从云端进度续播
struct HGCloudHistoryScreen: View {
    let rows: [HGCloudHistoryRow]
    let play: (HGCloudHistoryRow) -> Void
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(rows) { r in
                    Button { play(r) } label: { HGSeriesCard(series: r.series, subtitle: "看到第 \(max(1, r.vid_index)) 集") }
                        .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(HGTheme.background)
        .navigationTitle("继续观看")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 登录后的收藏「全部」页（红果 App 收藏 + 本机收藏）；本机收藏可长按取消
struct HGSeriesGridScreen: View {
    let title: String
    let items: [HGSeries]
    @State private var library = HGLibrary.shared
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { s in
                    NavigationLink(value: s) { HGSeriesCard(series: s, subtitle: s.episode_count.map { "共 \($0) 集" }) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if library.isFavorite(s.id) {
                                Button("取消本机收藏", systemImage: "heart.slash", role: .destructive) { library.toggleFavorite(s) }
                            }
                        }
                }
            }
            .padding(16)
        }
        .background(HGTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension HGCloudHistoryRow {
    func with(cover: String) -> HGCloudHistoryRow {
        HGCloudHistoryRow(series_id: series_id, series_title: series_title, cover: cover, episode_id: episode_id,
                          vid_index: vid_index, currentTime: currentTime, total: total, updatedAt: updatedAt)
    }
}

/// 设置（2026-11-26 老板：改美观一些）：iOS 设置同款——每行左边一个彩色圆角图标块，按「外观 / 播放 / 缓存 / 账号」分组，
/// 首页样式改叫「首页主题」（奈飞 / 红果），储存空间改叫「缓存管理」并直接显示当前缓存占用
struct HGMineSettings: View {
    let signedIn: Bool
    let onLogout: () -> Void
    @AppStorage("hg.bgPlay.v2") private var bgPlay = false
    @AppStorage(DYVideoAmbient.key) private var ambientLevel = DYVideoAmbient.defaultLevel
    @AppStorage(HGHomeStyle.key) private var homeStyle = HGHomeStyle.netflix.rawValue
    @AppStorage("hg.danmaku.on") private var danmakuOn = true
    @State private var cacheBytes: Int64?

    var body: some View {
        List {
            Section {
                HGSettingRow(icon: "rectangle.grid.1x2.fill", tint: HGTheme.accent, title: "首页主题") {
                    Picker("首页主题", selection: $homeStyle) {
                        Text("奈飞").tag(HGHomeStyle.netflix.rawValue)
                        Text("红果").tag(HGHomeStyle.classic.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 132)
                    .accessibilityIdentifier("hg.home.style")
                }
            } header: { Text("外观") } footer: {
                Text(homeStyle == HGHomeStyle.classic.rawValue ? "红果：两列瀑布流、榜单按分区排，跟红果 App 一样。" : "奈飞：大海报 + 一行一个榜单，横着滑。")
            }
            .listRowBackground(HGTheme.surface)

            Section {
                HGSettingRow(icon: "sun.max.fill", tint: .orange, title: "环境光") {
                    Picker("环境光", selection: $ambientLevel) {
                        ForEach(DYVideoAmbient.levels, id: \.self) { Text(DYVideoAmbient.title($0)).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("hg.settings.ambient")
                }
                HGSettingRow(icon: "text.bubble.fill", tint: .blue, title: "弹幕") {
                    Toggle("弹幕", isOn: $danmakuOn).labelsHidden().tint(HGTheme.accent)
                }
                HGSettingRow(icon: "headphones", tint: .purple, title: "听书模式", subtitle: "退出 App 后继续播放声音") {
                    Toggle("听书模式", isOn: $bgPlay).labelsHidden().tint(HGTheme.accent)
                }
            } header: { Text("播放") }
            .listRowBackground(HGTheme.surface)

            Section {
                NavigationLink { DYStorageScreen() } label: {
                    HGSettingRow(icon: "externaldrive.fill", tint: .green, title: "缓存管理", subtitle: "封面、播放缓存") {
                        if let cacheBytes {
                            Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                                .font(.subheadline.monospacedDigit()).foregroundStyle(HGTheme.textSecondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .accessibilityIdentifier("hg.settings.cache")
            } header: { Text("存储") }
            .listRowBackground(HGTheme.surface)

            // 乌力 wuli-tv-install：手机经 ADB 把电视版 APK 推到家里的安卓电视
            Section {
                NavigationLink { HGTVRemoteView() } label: {
                    HGSettingRow(icon: "appletvremote.gen4.fill", tint: .indigo, title: "连接遥控器", subtitle: "扫码 / 局域网连接 GuoDuo TV，手机电视互相接着看") { EmptyView() }
                }
                .accessibilityIdentifier("hg.mine.tvRemote")
                NavigationLink { HGTVInstallView() } label: {
                    HGSettingRow(icon: "tv.fill", tint: .teal, title: "安装到电视", subtitle: "局域网找安卓电视，一键装 GuoDuo TV") { EmptyView() }
                }
                .accessibilityIdentifier("hg.mine.tvInstall")
            } header: { Text("设备") }
            .listRowBackground(HGTheme.surface)

            HGAboutSection()

            if signedIn {
                Section {
                    Button(role: .destructive, action: onLogout) {
                        Text("退出红果账号").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("hg.mine.logout")
                }
                .listRowBackground(HGTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HGTheme.background)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadCacheSize() }
    }

    /// 只算缓存（封面 + 播放缓存 + 半截下载），不含 App 本体
    private func loadCacheSize() async {
        guard let u = try? await DYStorageFiles.shared.scan() else { return }
        cacheBytes = [.video, .images, .web].reduce(Int64(0)) { $0 + (u.categories[$1] ?? 0) }
    }
}

/// 设置行：左彩色圆角图标块 + 标题 / 小字说明 + 右侧控件
struct HGSettingRow<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(HGTheme.textPrimary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(HGTheme.textTertiary) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 2)
    }
}
