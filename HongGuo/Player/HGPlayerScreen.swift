import SwiftUI
import AVKit

/// DouDuo 式竖滑短剧播放页：一集一页，上下滑切集；手势层原样用 DouDuo 的 PlayerGestureView。
/// 推荐流把一屏播放页嵌进来时提供的回调
struct HGFeedHooks {
    /// 进整部剧（带上当前进度，第 1 集接着放）
    var openSeries: (Double) -> Void
    /// 书本姿态右侧选集：直接跳到第 i 集
    var openEpisode: (Int) -> Void
    /// 横屏返回键：推荐页回到发现
    var back: () -> Void = {}
    /// 桌面姿态触控板上下滑：下一部 / 上一部
    var next: () -> Void = {}
    var previous: () -> Void = {}
}

struct HGPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var session: HGPlaybackSession
    @State private var page: Int?
    @State private var library = HGLibrary.shared

    @AppStorage("hg.danmaku.on") private var danmakuOn = true
    @AppStorage(DYDanmakuPolicy.densityKey) private var danmakuDensity = DYDanmakuPolicy.Density.standard.rawValue
    @AppStorage(DYDanmakuStyle.opacityKey) private var danmakuOpacity = 1.0
    @AppStorage(DYDanmakuStyle.fontKey) private var danmakuFont = 17.0
    @AppStorage("hg.fillWidth") private var fillWidth = true
    /// 极简模式（DouDuo 同款）：不显示菜单栏和标题，只留右下一颗带进度外圈的返回圆键；
    /// 单击圆键弹菜单、按住看标题，点屏幕暂停时显示详情
    @AppStorage("hg.minimal") private var minimal = false
    /// 菜单栏顶边（屏幕坐标，未下推前）；外屏竖屏信号圈比安全区伸得更下，栏顶要躲开它
    @State private var railTopY: CGFloat = 999
    @State private var railPush: CGFloat = 0
    @State private var peek = false

    @State private var clean = false               // 沉浸式（原「全屏」）：只留画面
    /// 沉浸式下 2× 锁定提示只显示 5 秒（老板 2026-11-19 要求）
    @State private var lockBadgeExpired = false
    @State private var lockBadgeTask: Task<Void, Never>?
    @State private var showComments = false
    @State private var showEpisodes = false
    @State private var showMore = false
    @State private var commentTip = false
    @State private var commentTipTask: Task<Void, Never>?
    /// 评论是否占着一侧（侧滑 / 半折常驻）：本视图自己的 body 里算出来，不能用环境值读回自己
    @State private var commentsInPane = false
    /// 桌面姿态操作台在：弹幕搬到操作台上，视频上不再画
    @State private var consoleShown = false
    @AppStorage("hg.deskLight") private var deskLight = true
    /// 桌面姿态弹幕位置：false = 影片区（上半屏），true = 触控区（下半屏）
    @AppStorage("hg.danmaku.inConsole") private var danmakuInConsole = false
    @State private var consoleControls = false
    @State private var seeking = false
    @State private var seekPreview: Double = 0
    @State private var seekAnchor: Double = 0
    @State private var pinchScale: CGFloat = 1
    @State private var userScale: CGFloat = 1
    @State private var edgeOffset: CGFloat = 0
    @State private var toast: String?
    @State private var heartBurst = false
    @State private var landscape = false

    private static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    /// 推荐流：外面传进来的会话（一部剧一个），竖滑由外层推荐页接管，本页只画一屏
    private let feed: HGFeedHooks?

    init(request: HGPlayerRequest) {
        _session = State(initialValue: HGPlaybackSession(request))
        _page = State(initialValue: request.index)
        feed = nil
    }

    init(feedSession: HGPlaybackSession, hooks: HGFeedHooks) {
        _session = State(initialValue: feedSession)
        _page = State(initialValue: feedSession.index)
        feed = hooks
    }

    /// DouDuo DYCommentStage / DYCommentPlayerLayout 同一套几何（原样搬的 DYCommentPaneMetrics）：
    /// - 内屏平放 / 横屏（宽 ≥ 700）：点评论 → 视频缩窄，评论从右侧滑出
    /// - 半折叠书本：左视频、右评论常驻；桌面：上视频、下评论常驻 + 倒影环境光（dyDeskLight）
    /// - 外屏 / 普通竖屏：贴边底部液态玻璃面板
    var body: some View {
        GeometryReader { outer in
            let showsComments = showComments && session.series.source == .hongguo
            let layout = DYCommentPaneMetrics(outer, isPresented: showsComments, allowsResident: true)
            ZStack(alignment: .topLeading) {
                pager
                    .frame(width: layout.videoSize.width, height: layout.videoSize.height)
                    .clipped()
                if layout.resident && !layout.sideBySide {
                    // 竖屏半折叠（桌面）：下半屏 = 全黑操作台
                    HGConsolePane(session: session, deskLight: $deskLight, controlsShown: $consoleControls,
                                  danmakuOn: $danmakuOn, danmakuInConsole: $danmakuInConsole,
                                  creaseTop: layout.creaseInset, videoHeight: layout.videoSize.height,
                                  bottomInset: DYDuoMetrics.windowBottomInset,
                                  onBack: { if let feed { feed.back() } else { dismiss() } },
                                  onEpisodes: { if let feed { feed.openSeries(session.position) } else { showEpisodes = true } },
                                  onMore: { showMore = true },
                                  flash: { flash($0) },
                                  onNext: {
                                      if let feed { feed.next() }
                                      else if session.hasNext { session.next() } else { flash("已经是最后一集") }
                                  },
                                  onPrevious: {
                                      if let feed { feed.previous() }
                                      else if session.index > 0 { session.previous() } else { flash("已经是第一集") }
                                  })
                        .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                        .clipped()
                        .offset(x: layout.paneOrigin.x, y: layout.paneOrigin.y)
                        .transition(.move(edge: .bottom))
                } else if layout.resident && layout.sideBySide && showsComments {
                    // 书本姿态点了评论：右半屏临时换成评论，关掉回选集
                    HGCommentPanel(series: session.series, episode: session.episode, total: session.episodeStat?.comments,
                                   onClose: { showComments = false },
                                   fillsPane: true, trailingInset: layout.trailingInset,
                                   horizontalStatus: true, swipeRightClosesAnywhere: true)
                        .id(session.episode.vid)
                        .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                        .clipped()
                        .overlay(alignment: .leading) { Color(uiColor: .separator).frame(width: 0.5) }
                        .offset(x: layout.paneOrigin.x, y: layout.paneOrigin.y)
                        .transition(.move(edge: .trailing))
                        .accessibilityIdentifier("hg.comments.side")
                } else if layout.resident && layout.sideBySide {
                    // 横屏半折叠（书本）：右半屏 = 选集
                    HGEpisodeSheet(session: session, close: {}, fillsPane: true, trailingInset: layout.trailingInset,
                                   onPick: feed.map { f in { i in f.openEpisode(i) } })
                        .padding(.top, DYDuoMetrics.isDuoHardware ? 0 : DYDuoMetrics.windowSafeTop)
                        .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                        .clipped()
                        .overlay(alignment: .leading) { Color(uiColor: .separator).frame(width: 0.5) }
                        .offset(x: layout.paneOrigin.x, y: layout.paneOrigin.y)
                        .transition(.move(edge: .trailing))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("hg.episodes.resident")
                } else if layout.showsPane {
                    HGCommentPanel(series: session.series, episode: session.episode, total: session.episodeStat?.comments,
                                   onClose: { showComments = false },
                                   fillsPane: true, trailingInset: layout.trailingInset,
                                   horizontalStatus: true, swipeRightClosesAnywhere: true)
                        .id(session.episode.vid)
                        .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                        .clipped()
                        .overlay(alignment: .leading) {
                            if layout.sideBySide { Color(uiColor: .separator).frame(width: 0.5) }
                        }
                        .offset(x: layout.paneOrigin.x, y: layout.paneOrigin.y)
                        .transition(.move(edge: .trailing))
                        .accessibilityIdentifier("hg.comments.side")
                }
            }
            .frame(width: outer.size.width, height: outer.size.height, alignment: .topLeading)
            .background(Color.black.ignoresSafeArea())
            // 书本姿态：右边是常驻选集，视频上照常显示完整菜单栏（右侧 DouDuo 液态玻璃栏）
            .onChange(of: layout.showsPane && !(layout.resident && layout.sideBySide && !showsComments), initial: true) { _, v in commentsInPane = v }
            .onChange(of: layout.resident && !layout.sideBySide, initial: true) { _, v in consoleShown = v }
            .animation(.snappy, value: layout.showsPane)
            .animation(.snappy, value: layout.resident)
            .dyBottomSheet(isPresented: Binding(
                get: { showsComments && !layout.sideBySide && !layout.resident },
                set: { if !layout.sideBySide && !layout.resident { showComments = $0 } }
            ), kind: .comments) {
                HGCommentPanel(series: session.series, episode: session.episode, total: session.episodeStat?.comments,
                               onClose: { showComments = false })
            }
        }
        .modifier(DYHingeStateRoot())
        .ignoresSafeArea()
        .statusBarHidden(clean)
        .persistentSystemOverlays(clean ? .hidden : .automatic)
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showMore) {
            moreSheet
                .presentationDetents([.height(moreSheetHeight), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(HGTheme.surface)
        }
        .sheet(isPresented: $showEpisodes) {
            HGEpisodeSheet(session: session) { showEpisodes = false }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .onAppear {
            if feed == nil { session.start() }
            #if DEBUG
            if ProcessInfo.processInfo.environment["HG_DEMO_PAUSE"] == "1" {
                Task {
                    for _ in 0..<40 {   // 等真正开播（取源 + 下载要几秒），再播 3 秒后暂停
                        try? await Task.sleep(for: .seconds(1))
                        if session.isPlaying && session.position > 3 { session.togglePlay(); return }
                    }
                }
            }
            if ProcessInfo.processInfo.environment["HG_DEMO_COMMENTS"] == "1" {
                Task { try? await Task.sleep(for: .seconds(6)); showComments = true }
            }
            #endif
        }
        .onAppear { HGOrientation.playerAppeared() }
        .onDisappear {
            if feed == nil { session.stop() }
            HGOrientation.playerDisappeared()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, !HGBackgroundPlayback.enabled, !session.pip.active, !session.pip.starting { session.pauseForBackground() }
        }
        .onChange(of: session.lockedBoost) { _, _ in restartLockBadgeTimer() }
        .onChange(of: clean) { _, _ in restartLockBadgeTimer() }
    }

    /// 沉浸式下锁定 2× 后，提示只留 5 秒；退出沉浸式或重新锁定会重新显示
    private func restartLockBadgeTimer() {
        lockBadgeTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { lockBadgeExpired = false }
        guard clean, session.lockedBoost else { return }
        lockBadgeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { lockBadgeExpired = true }
        }
    }

    @ViewBuilder private var pager: some View {
        if feed != nil {
            GeometryReader { geo in
                pageView(session.index, session.episode, size: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()
            .background(Color.black)
        } else {
            episodePager
        }
    }

    private var episodePager: some View {
        GeometryReader { geo in
          ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(session.episodes.enumerated()), id: \.element.id) { i, ep in
                        pageView(i, ep, size: geo.size)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(i)
                    }
                }
                .scrollTargetLayout()
                .hgDisableScrollToTop()   // 点屏幕顶部不再跳回第 1 集
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .scrollDisabled(seeking)
            .ignoresSafeArea()
            .background(Color.black)
            .offset(x: edgeOffset)
            .onChange(of: page) { _, p in if let p, p != session.index { session.go(to: p) } }
            .onChange(of: session.index) { _, i in if page != i { withAnimation(.easeInOut(duration: 0.3)) { page = i } } }
            // scrollPosition 的初值对 LazyVStack 不生效：首帧后显式滚到起始集
            .onAppear { proxy.scrollTo(session.index, anchor: .top); page = session.index }
          }
        }
    }

    // MARK: 一页

    @ViewBuilder
    private func pageView(_ i: Int, _ ep: HGEpisode, size: CGSize) -> some View {
        ZStack {
            Color.black
            if i == session.index {
                DYAmbientBackdrop(player: session.player, active: true, dim: 0.6, fillWidth: fillWidth)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                HGVideoLayer(player: session.player, fillWidth: fillWidth, pip: session.pip,
                             onReadyForDisplay: { [session] in session.setDisplayReady($0) })
                    .scaleEffect(userScale * pinchScale)
                    .clipped()
                // 第一帧出来之前盖着预取的首帧：滑过来不黑屏、不像卡住
                if !session.displayReady, let poster = session.posters[ep.vid] {
                    posterView(poster, size: size).allowsHitTesting(false)
                }
                if danmakuOn && !clean && (!consoleShown || !danmakuInConsole) {
                    DYDanmakuLayer(items: session.danmaku, clock: session.clock, topInset: safeTop, fullPane: consoleShown)
                        .accessibilityElement()
                        .accessibilityIdentifier("hg.player.danmaku")
                        .accessibilityValue("\(session.danmaku.count)")
                }
                PlayerGestureView(
                    onSingleTap: { session.togglePlay() },
                    onDoubleTap: { _, _ in doubleTapLike() },
                    onLongPress: { pressing in session.setBoost(pressing) },
                    onLongPressLock: { session.lockBoost(); flash("已锁定 2× 倍速") },
                    onLongPressUnlock: { session.unlockBoost(); flash("已解锁") },
                    onSeekBegan: { seekAnchor = session.position; seekPreview = session.position; seeking = true },
                    onSeekChanged: { dx, w in
                        seekPreview = max(0, min(session.duration, seekAnchor + dx / max(w, 1) * session.duration * 0.9))
                        session.requestPreview(seekPreview)
                    },
                    onSeekEnded: { if seeking { session.seek(to: seekPreview); seeking = false; session.endPreview() } },
                    onEdgeChanged: { if feed == nil { edgeOffset = $0 } },
                    onEdgeEnded: { dx, v, w in
                        if feed == nil, dx > w * 0.3 || v > 800 { dismiss() } else { withAnimation(.spring(duration: 0.25)) { edgeOffset = 0 } }
                    },
                    verticalFirst: true,
                    onPinchBegan: {},
                    onPinchChanged: { pinchScale = $0 },
                    onPinchEnded: { s in
                        userScale = max(1, min(3, userScale * s)); pinchScale = 1
                        if userScale < 1.05 { withAnimation(.spring(duration: 0.25)) { userScale = 1 } }
                    },
                    onPinchCancelled: { pinchScale = 1 })
                    .accessibilityElement()
                    .accessibilityIdentifier("hg.player.surface")
                    .accessibilityValue(session.isPlaying && session.position > 0.5 && page == i ? "playing-\(ep.number)" : "idle")
                    .accessibilityHint("pos=\(Int(session.position))")
                if heartBurst { Image(systemName: "heart.fill").font(.system(size: 96)).foregroundStyle(HGTheme.accent).transition(.scale.combined(with: .opacity)).allowsHitTesting(false) }
                if !session.isPlaying && session.status == nil && session.failed == nil && !seeking {
                    Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.75)).allowsHitTesting(false)
                }
                if session.boosting || (session.lockedBoost && !lockBadgeExpired) { boostBadge }
                if seeking && !consoleShown { seekOverlay }
                statusOverlay
                if clean { exitCleanButton } else if consoleShown { consoleTitle(ep) } else { chrome(ep) }   // 横屏评论从右滑出时，视频缩到左边，菜单栏仍贴视频右侧
            } else if let poster = session.posters[ep.vid] {
                // 已预下的集：滑动途中就是本集第一帧真画面
                posterView(poster, size: size).allowsHitTesting(false)
            } else {
                // 相邻页只显示封面占位，滑动时不黑屏
                HGCover(url: session.series.coverURL).blur(radius: 18).opacity(0.35).allowsHitTesting(false)
                Text("第 \(ep.number) 集").font(.headline).foregroundStyle(.white.opacity(0.7))
            }
        }
        .clipped()
    }

    /// 首帧海报：铺满规则与画面层一致（DYVideoFit）
    private func posterView(_ img: UIImage, size: CGSize) -> some View {
        let fill = DYVideoFit.presentation(fillWidth: fillWidth, videoAspect: img.size.width / max(img.size.height, 1),
                                           screenAspect: size.width / max(size.height, 1)) == .aspectFill
        return Image(uiImage: img).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            .frame(width: size.width, height: size.height).clipped()
            .accessibilityIdentifier("hg.player.poster")
    }

    // MARK: 叠加层

    private var safeTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.top ?? 47
    }

    /// DouDuo 默认模式布局：左下信息、右侧玻璃按钮栏底部对齐，左右 12pt，底部给进度条留位；返回键是玻璃圆。
    private func chrome(_ ep: HGEpisode) -> some View {
        // 横屏（宽 > 高）：返回键并到右侧菜单栏最上面（跟首页右侧胶囊一个位置逻辑）
        let wide = isLandscapeWindow
        // 返回键放到右侧菜单栏最上面：推荐页、完整播放页，外屏 / 展开、横竖屏一律这样（老板 2026-11-19）
        let backOnRail = true
        _ = wide
        // 极简：菜单栏不变；标题平时隐藏（暂停 / 按住返回键时显示），进度条画成返回键外圈
        let paused = !session.isPlaying && session.status == nil && session.failed == nil && !seeking
        let showInfo = !minimal || peek || paused
        // 矮屏（外屏横屏只有 ~466pt 高）：菜单栏整列放不下会顶出屏幕上沿 →
        // 先把栏底的 56 让出来（栏往下移），还不够再整列等比缩小，保证返回键到「更多」全在屏内
        let fit = railFit(backOnRail: backOnRail)
        let push = max(0, (max(safeTop, 12) + statusClearance) - railTopY)
        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if !backOnRail { backButton }
                    Spacer()
                    if let notice = session.danmakuNotice, danmakuOn {
                        Text(notice).font(.caption2).foregroundStyle(DDMedia.onMediaSecondary).ddMediaLabelShadow()
                    }
                }
                .padding(.horizontal, DDMedia.chromeSidePadding).padding(.top, safeTop)
                Spacer()
            }
            // DouDuo 默认模式的数值：栏整体 offset(x: -9)（compact）、栏底 56、整行离底 max(安全区,18)+36；进度条在这 36 里
            HStack(alignment: .bottom, spacing: 12) {
                if showInfo { info(ep).transition(.opacity).accessibilityIdentifier("hg.player.info") }
                Spacer(minLength: 0)
                VStack(spacing: DDMedia.actionGroupSpacing) {
                    if backOnRail {
                        backButton.frame(width: DDMedia.actionColumnWidth)
                    }
                    rail
                }
                // DouDuo 默认模式同款：先按系统右侧栏（横屏状态栏列）让位，再按遮挡区（外屏摄像头）微调
                .offset(x: DYDuoMetrics.actionRailHorizontalOffset(
                    isRegular: hSize == .regular, trailingInset: systemColumnInset,
                    columnWidth: DDMedia.actionColumnWidth, outerPadding: DDMedia.chromeSidePadding))
                .scaleEffect(fit.scale, anchor: .bottomTrailing)
                .background(GeometryReader { g in
                    Color.clear.onChange(of: g.frame(in: .global).minY, initial: true) { _, y in
                        // 只记"没被推之前"的位置：减掉当前推量，避免推完再推的抖动
                        let raw = y - railPush
                        if abs(raw - railTopY) > 1 { railTopY = raw }
                    }
                })
                .offset(x: hSize == .compact ? -9 : 0, y: push)
                .onChange(of: push, initial: true) { _, p in railPush = p }
                .padding(.bottom, fit.bottom)
            }
            .padding(.horizontal, DDMedia.chromeSidePadding)
            .padding(.bottom, max(safeBottom, 18) + 36)
            if !minimal { progressBar.padding(.bottom, max(safeBottom, 18) + 4) }
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.15), value: showInfo)
    }

    /// 菜单栏顶边离屏幕上沿至少多少。Duo 外屏竖屏真机实测：窗口安全区顶读出来是 0，
    /// 右上信号 / 时间 / 电量胶囊实际占到 y≈120pt（截图 360px ÷ 3）→ 栏顶压到 168pt 以下，留 ~48pt 空隙；
    /// 内屏 / 普通 iPhone 信号在安全区里，安全区下再空 16 就够
    private var statusClearance: CGFloat {
        guard DYDuoMetrics.isDuoHardware,
              let w = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.bounds.size,
              w.width < 600 else { return 16 }
        return w.width < w.height ? 156 : 16
    }

    /// 菜单栏整列的自然高度（DDActionRail 的数值：每格有字 50 / 无字 36，格距 9，胶囊上下 8，胶囊到「更多」12，「更多」50）
    private func railFit(backOnRail: Bool) -> (bottom: CGFloat, scale: CGFloat) {
        let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.bounds.size ?? .zero
        var cells: [CGFloat] = []
        if feed != nil { cells.append(50) }
        if session.series.source == .hongguo { cells += [50, 50] }
        cells += [50, 36]
        var natural = cells.reduce(0, +) + CGFloat(max(0, cells.count - 1)) * DDMedia.actionItemSpacing + 16
        natural += DDMedia.actionGroupSpacing + 50
        if backOnRail { natural += 44 + DDMedia.actionGroupSpacing }
        // 栏下面固定要留的：进度条那 36 + 底部安全区；
        // 栏上面要躲开右上角的信号 / 时间圈：顶部安全区再加 16pt 间隙（外屏的信号圈比安全区还往下伸）
        let below = max(safeBottom, 18) + 36
        let above = max(safeTop, 12) + statusClearance
        let room = window.height - below - above
        guard window.height > 0 else { return (56, 1) }
        if room >= natural + 56 { return (56, 1) }
        let bottom = max(8, room - natural)
        let scale = min(1, max(0.6, (room - bottom) / natural))
        return (bottom, scale)
    }

    /// 系统右侧栏宽（横屏时状态栏竖在右边）：全屏播放层读到的安全区为 0，只能读窗口（DouDuo systemColumnInset 同款）
    private var systemColumnInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.safeAreaInsets.right ?? 0
    }

    private var isLandscapeWindow: Bool {
        guard let w = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.bounds.size else { return false }
        return w.width > w.height
    }

    @ViewBuilder private var backButton: some View {
        if minimal { ringBackButton } else {
            Button { goBack() } label: {
                Image(systemName: "chevron.backward")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .ddMediaGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hg.player.close")
        }
    }

    private func goBack() { if let feed { feed.back() } else { dismiss() } }

    /// 极简返回键：DouDuo 极简入口同款——外圈是视频进度（环 50pt、线宽 3.2、底轨 22%，12 点顺时针，拖进度变粗）；
    /// 单击返回，按住显示标题、松手消失
    private var ringBackButton: some View {
        let d: CGFloat = 50, lw: CGFloat = 3.2
        let pos = seeking ? seekPreview : session.position
        let frac = session.duration > 0 ? min(1, max(0, pos / session.duration)) : 0
        return ZStack {
            Image(systemName: "chevron.backward")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: d - 8, height: d - 8)
                .ddMediaGlassCircle()
            Circle().stroke(.white.opacity(0.22), lineWidth: lw).padding(lw / 2)
            Circle()
                .trim(from: 0, to: max(frac, 0.004))
                .stroke(.white, style: StrokeStyle(lineWidth: seeking ? lw + 1.5 : lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lw / 2)
                .animation(.linear(duration: 0.25), value: frac)
        }
        .frame(width: d, height: d)
        .contentShape(Circle())
        .modifier(DDPressHold(threshold: 0.35, onPressChanged: { pressing in
            withAnimation(.easeOut(duration: pressing ? 0.1 : 0.15)) { peek = pressing }
        }, onTap: { goBack() }))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("返回")
        .accessibilityIdentifier("hg.player.close")
        .accessibilityValue("\(Int(frac * 100))%")
        .accessibilityAction { goBack() }
    }

    /// 第 5 集以后：评论按钮旁边弹一个小气泡，2.5 秒自动收
    private func showCommentTip() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        commentTipTask?.cancel()
        withAnimation(.snappy) { commentTip = true }
        commentTipTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { commentTip = false }
        }
    }

    /// 评论按钮左侧的提示气泡（锚在菜单栏上，跟着栏走：视频上 / 操作台右栏都适用）
    private var commentTipBubble: some View {
        Text("第 \(HGCommentPolicy.publicEpisodes) 集以后的评论，目前不支持观看")
            .font(.caption.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .ddMediaGlassCapsule()
            .fixedSize()
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            .accessibilityIdentifier("hg.comments.lockedTip")
    }

    /// 桌面姿态：控制面板呼出时视频左上角显示剧名 + 第几集 · 时长，跟面板一起收
    @ViewBuilder private func consoleTitle(_ ep: HGEpisode) -> some View {
        if consoleControls {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.series.series_title).font(.headline).lineLimit(1)
                Text("第\(ep.number)集" + (session.duration > 0 ? " | \(Int((session.duration / 60).rounded(.up)))分钟" : ""))
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(.white)
            .ddMediaLabelShadow()
            .padding(.leading, 16).padding(.top, max(safeTop, 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityIdentifier("hg.console.title")
        }
    }

    /// 桌面姿态操作台右侧竖栏：返回键在上，下面就是视频上那根 DouDuo 菜单栏
    private var consoleColumn: some View {
        VStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward").font(.title2.weight(.medium)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).contentShape(Circle()).ddMediaGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hg.player.close")
            rail
        }
        .environment(\.horizontalSizeClass, .compact)
    }

    /// 评论占一侧时视频上只留返回键（DouDuo：评论打开 / 常驻时按钮栏直接隐藏）
    private var paneChrome: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.backward").font(.title2.weight(.medium)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).contentShape(Circle()).ddMediaGlassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hg.player.close")
                Spacer()
            }
            .padding(.horizontal, DDMedia.chromeSidePadding).padding(.top, safeTop)
            Spacer()
            if !consoleShown { progressBar.padding(.bottom, 12) }
        }
    }

    private var safeBottom: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom ?? 34
    }

    /// 左下信息：剧名（加粗）+ 集数 / 播放量（次要色），DouDuo 信息区同款字号与阴影
    private func info(_ ep: HGEpisode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.series.series_title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 8) {
                Text(feed == nil ? "第 \(ep.number) 集 · 共 \(session.episodes.count) 集" : "推荐 · 第 \(ep.number) 集")
                if let plays = session.stats?.plays { Text("\(DDMedia.count(plays))次播放") }
            }
            .font(.subheadline).foregroundStyle(DDMedia.onMediaSecondary)
            if let d = session.series.description, !d.isEmpty {
                Text(d).font(.subheadline).foregroundStyle(.white).lineLimit(2)
            }
        }
        .ddMediaLabelShadow()
    }

    /// DouDuo 同款右侧栏：玻璃胶囊（点赞 / 评论 / 收藏 / 铺满）+ 玻璃圆「更多」
    private var rail: some View {
        let fav = library.isFavorite(session.series.id)
        let liked = library.isLiked(session.episode.vid)
        let stat = session.episodeStat
        var items: [DDActionRail.Item] = []
        if let feed {
            items.append(.init(id: "hg.feed.watchAll", icon: "rectangle.stack", text: "全集") { feed.openSeries(session.position) })
        }
        if session.series.source == .hongguo {
            items.append(.init(id: "hg.rail.likes", icon: liked ? "heart.fill" : "heart",
                               text: stat?.likes.map { DDMedia.count($0 + (liked ? 1 : 0)) } ?? "",
                               tint: liked ? DDMedia.danger : .white) { toggleLike() })
            let locked = session.episode.number > HGCommentPolicy.publicEpisodes
            items.append(.init(id: "hg.rail.comments", icon: "ellipsis.bubble",
                               text: stat?.comments.map(DDMedia.count) ?? "",
                               tint: locked ? .white.opacity(0.45) : .white) {
                if locked { showCommentTip() } else { showComments = true }
            })
        }
        items.append(.init(id: "hg.rail.favorite", icon: fav ? "star.fill" : "star",
                           text: session.stats?.follows.map { DDMedia.count($0 + (fav ? 1 : 0)) } ?? "",
                           tint: fav ? DDMedia.warning : .white) { library.toggleFavorite(session.series) })
        items.append(.init(id: "hg.rail.fill", icon: "fit", text: "", fitInward: !fillWidth) {
            fillWidth.toggle(); userScale = 1
            flash(fillWidth ? "铺满：开" : "完整画面")
        })
        return DDActionRail(items: items) { showMore = true }
            .overlay(alignment: .topLeading) {
                if commentTip {
                    // 宽 0 + 右对齐：气泡从栏左边缘往左长，不会出屏
                    commentTipBubble
                        .frame(width: 0, height: 34, alignment: .trailing)
                        .offset(x: -10, y: 92 - 17)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hg.rail")
            .accessibilityValue(fav ? "已收藏" : "未收藏")
    }

    /// 「更多」面板（2026-11-19 老板：竖屏 / 横屏展开都不协调、标题压在拖动条上）：
    /// 顶部让开拖动条；内容限宽 560 居中；功能格用自适应列（宽屏不再被拉散）；
    /// 下面是倍速、弹幕（密度 / 透明度 / 字号）两组，统一「标签在左、选项在右」；放不下就滚动。
    private var moreSheet: some View {
        GeometryReader { g in
        // 内容宽：面板宽减两侧 20，最宽 600（展开横屏不铺散）；功能格按宽度分列（每格 ≥70）、等分铺满
        // 外屏右侧有系统状态栏列，安全区会把内容往左挤、右边空一截——面板在它下面，横向忽略安全区
        let w = min(g.size.width - 40, 600)
        let cols = max(4, min(7, Int(w / 70)))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(session.title).font(.headline).lineLimit(1).foregroundStyle(HGTheme.textPrimary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), alignment: .leading, spacing: 14) {
                    if consoleShown { socialItems }
                    moreItem("list.number", feed == nil ? "选集" : "看全集", id: "hg.more.episodes") {
                        showMore = false
                        if let feed { feed.openSeries(session.position) } else { showEpisodes = true }
                    }
                    moreItem(danmakuOn ? "captions.bubble.fill" : "captions.bubble", danmakuOn ? "关弹幕" : "开弹幕", on: danmakuOn, id: "hg.more.danmaku") { danmakuOn.toggle() }
                    moreItem("rectangle", minimal ? "退出极简" : "极简模式", on: minimal, id: "hg.more.minimal") {
                        showMore = false
                        withAnimation(.easeOut(duration: 0.2)) { minimal.toggle() }
                        flash(minimal ? "极简模式：按住返回键看标题，暂停时显示详情" : "已退出极简")
                    }
                    moreItem("arrow.up.left.and.arrow.down.right.rectangle", "沉浸式", id: "hg.more.clean") {
                        showMore = false; withAnimation(.easeOut(duration: 0.2)) { clean = true }
                    }
                    if session.pip.supported {
                        moreItem("pip.enter", "画中画", id: "hg.more.pip") { showMore = false; session.pip.start() }
                    }
                    if session.videoAspect > 1.05 {
                        moreItem("rotate.right", landscape ? "竖屏" : "横屏", id: "hg.more.rotate") { showMore = false; setOrientation(landscape: !landscape) }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    sheetGroup("播放")
                    optionRow("倍速") {
                        ForEach(Self.rates, id: \.self) { r in
                            sheetPill(String(format: "%g×", r), on: r == session.rate, id: "hg.more.rate.\(r)") { session.setRate(r) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    sheetGroup("弹幕")
                    optionRow("密度") {
                        ForEach(DYDanmakuPolicy.Density.allCases) { d in
                            sheetPill(d.title, on: danmakuDensity == d.rawValue, id: "hg.danmaku.density.\(d.rawValue)") { danmakuDensity = d.rawValue }
                        }
                    }
                    optionRow("透明度") {
                        ForEach(DYDanmakuStyle.opacities, id: \.value) { o in
                            sheetPill(o.title, on: abs(danmakuOpacity - o.value) < 0.01, id: "hg.danmaku.opacity.\(Int(o.value * 100))") { danmakuOpacity = o.value }
                        }
                    }
                    optionRow("字号") {
                        ForEach(DYDanmakuStyle.fontSizes, id: \.size) { f in
                            sheetPill(f.title, on: abs(danmakuFont - f.size) < 0.1, id: "hg.danmaku.font.\(Int(f.size))") { danmakuFont = f.size }
                        }
                    }
                }
                .disabled(!danmakuOn).opacity(danmakuOn ? 1 : 0.45)
            }
            .frame(width: w, alignment: .leading)
            .padding(.top, 28)      // 让开系统拖动条
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .background(HGTheme.surface)
        .accessibilityIdentifier("hg.more.sheet")
    }

    private func sheetGroup(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(HGTheme.textSecondary)
    }

    private func optionRow<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(HGTheme.textSecondary).frame(width: 46, alignment: .leading)
            content()
        }
    }

    private func sheetPill(_ title: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(on ? .semibold : .regular).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(on ? HGTheme.accent : HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: HGTheme.radiusSmall, style: .continuous))
                .foregroundStyle(on ? Color.white : HGTheme.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityValue(on ? "on" : "off")
    }

    /// 「更多」默认高度：内容自然高度（标题 + 两排功能 + 倍速 + 弹幕三行 ≈ 470，桌面姿态多一排社交 ≈ 560），不超过屏高 72%
    private var moreSheetHeight: CGFloat {
        let h = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.bounds.height ?? 700
        return min(consoleShown ? 540 : 460, h * 0.8)
    }

    /// 桌面姿态没有右侧栏：点赞 / 评论 / 收藏 / 画面收进「更多」
    @ViewBuilder private var socialItems: some View {
        let fav = library.isFavorite(session.series.id)
        let liked = library.isLiked(session.episode.vid)
        let stat = session.episodeStat
        if session.series.source == .hongguo {
            moreItem(liked ? "heart.fill" : "heart", stat?.likes.map { DDMedia.count($0 + (liked ? 1 : 0)) } ?? "点赞",
                     on: liked, id: "hg.more.like") { toggleLike() }
            let locked = session.episode.number > HGCommentPolicy.publicEpisodes
            moreItem("ellipsis.bubble", locked ? "评论" : (stat?.comments.map { DDMedia.count($0) + "评论" } ?? "评论"),
                     id: "hg.more.comments") {
                if locked { flash("第 \(HGCommentPolicy.publicEpisodes) 集以后的评论，目前不支持观看") }
                else { showMore = false; showComments = true }
            }
        }
        moreItem(fav ? "star.fill" : "star", fav ? "已收藏" : "收藏", on: fav, id: "hg.more.favorite") { library.toggleFavorite(session.series) }
        moreItem("aspectratio", fillWidth ? "完整画面" : "铺满", id: "hg.more.fill") {
            fillWidth.toggle(); userScale = 1; flash(fillWidth ? "铺满：开" : "完整画面")
        }
    }

    private func moreItem(_ icon: String, _ title: String, on: Bool = false, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3).frame(width: 52, height: 52)
                    .background(on ? HGTheme.accent.opacity(0.2) : HGTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
                    .foregroundStyle(on ? HGTheme.accent : HGTheme.textPrimary)
                Text(title).font(.caption).foregroundStyle(HGTheme.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }


    private var progressBar: some View {
        GeometryReader { g in
            let pos = seeking ? seekPreview : session.position
            let frac = session.duration > 0 ? min(1, max(0, pos / session.duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: seeking ? 6 : 3)
                Capsule().fill(.white).frame(width: g.size.width * frac, height: seeking ? 6 : 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !seeking { seeking = true }
                    seekPreview = max(0, min(session.duration, v.location.x / max(g.size.width, 1) * session.duration))
                    session.requestPreview(seekPreview)
                }
                .onEnded { _ in session.seek(to: seekPreview); seeking = false; session.endPreview() })
        }
        .frame(height: 24)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("hg.player.progress")
    }

    private var seekOverlay: some View {
        VStack(spacing: 8) {
            let vertical = session.videoAspect < 1
            Group {
                if let img = session.seekPreviewImage {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.4).overlay(ProgressView().tint(.white))
                }
            }
            .frame(width: vertical ? 124 : 196, height: vertical ? 220 : 110)
            .clipShape(RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
            .accessibilityIdentifier("hg.player.seekPreview")
            HStack(spacing: 8) {
                Text(fmt(seekPreview)).font(.subheadline.weight(.bold).monospacedDigit())
                Text("/ " + fmt(session.duration)).font(.caption.monospacedDigit()).opacity(0.6)
                let delta = seekPreview - session.position
                Text((delta >= 0 ? "+" : "") + String(format: "%.0fs", delta)).font(.caption.weight(.semibold))
                    .foregroundStyle(delta >= 0 ? HGTheme.textPrimary : HGTheme.textSecondary)
            }
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: HGTheme.radius, style: .continuous))
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    /// 长按 2× / 锁定提示：屏幕最上方居中（2026-11-19 老板要求）
    private var boostBadge: some View {
        Text(session.lockedBoost ? "2× 已锁定 · 上滑解锁" : "2× 快进中 · 下滑锁定")
            .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)   // 沉浸式与普通状态同一位置：最上方
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityIdentifier("hg.player.boostBadge")
    }

    @ViewBuilder private var statusOverlay: some View {
        if let status = session.status {
            VStack(spacing: 10) { ProgressView().tint(.white); Text(status).font(.footnote).foregroundStyle(.white.opacity(0.8)) }
                .allowsHitTesting(false)
        }
        if let failed = session.failed {
            VStack(spacing: 12) {
                Text(failed).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                HStack {
                    Button("重试") { session.retry() }.buttonStyle(.borderedProminent).tint(HGTheme.accent)
                    if session.hasNext { Button("下一集") { session.next() }.buttonStyle(.bordered).tint(.white) }
                }
            }
            .padding(32)
        }
    }

    private var exitCleanButton: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { clean = false } } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.footnote.weight(.semibold))
                .padding(10).background(.black.opacity(0.4), in: Circle()).foregroundStyle(.white.opacity(0.85))
        }
        .accessibilityIdentifier("hg.player.exitClean")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 16).padding(.bottom, 36)
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white)
                .padding(.top, safeTop + 50).transition(.opacity)
        }
    }

    // MARK: 动作

    /// 点赞只记在本机（红果账号登录也是只读，没法替你在官方点赞）；数字显示官方点赞数 + 自己这一下。
    private func toggleLike() { library.toggleLike(session.episode.vid) }

    private func doubleTapLike() {
        if !library.isLiked(session.episode.vid) { library.toggleLike(session.episode.vid) }
        withAnimation(.spring(duration: 0.25)) { heartBurst = true }
        Task { try? await Task.sleep(for: .milliseconds(650)); withAnimation(.easeOut(duration: 0.2)) { heartBurst = false } }
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation { if toast == s { toast = nil } } }
    }

    private func setOrientation(landscape on: Bool) {
        landscape = on
        HGOrientation.allowLandscape = on
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscapeRight : .portrait))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }


    private func rateText(_ r: Float) -> String { String(format: "%g×", r) }
    private func fmt(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// AVPlayerLayer + DouDuo 同款铺满规则（只在视频与屏幕同向时铺满）+ 画中画挂载。
struct HGVideoLayer: UIViewRepresentable {
    let player: AVPlayer
    let fillWidth: Bool
    let pip: DYPictureInPicture
    var onReadyForDisplay: ((Bool) -> Void)? = nil
    /// 同一个 AVPlayer 复用同一块画面层：推荐页预热的下一部转正时，页面从「预热画面」换成完整播放页，
    /// 新建 AVPlayerLayer 会让解码管线重建（真机：起播 1.5 秒、播 1 秒跳回开头）。挪同一个 view 过去就不重建
    private static let views = NSMapTable<AVPlayer, HGPlayerLayerView>.weakToWeakObjects()

    func makeUIView(context: Context) -> HGPlayerLayerView {
        if let v = Self.views.object(forKey: player) {
            v.removeFromSuperview()
            v.fillWidth = fillWidth
            v.onReadyForDisplay = onReadyForDisplay
            return v
        }
        let v = HGPlayerLayerView()
        Self.views.setObject(v, forKey: player)
        v.playerLayer.player = player
        v.fillWidth = fillWidth
        v.onReadyForDisplay = onReadyForDisplay
        v.pip = pip
        pip.prepareManual(layer: v.playerLayer)   // 不建控制器：退出 App 不会自动画中画
        return v
    }
    func updateUIView(_ v: HGPlayerLayerView, context: Context) {
        if v.playerLayer.player !== player, UIApplication.shared.applicationState != .background { v.playerLayer.player = player }
        v.fillWidth = fillWidth
        v.applyGravity()
    }
}

final class HGPlayerLayerView: UIView {
    var fillWidth = true
    weak var pip: DYPictureInPicture?
    var onReadyForDisplay: ((Bool) -> Void)? { didSet { onReadyForDisplay?(playerLayer.isReadyForDisplay) } }
    private var readyObs: NSKeyValueObservation?
    private var sizeObs: NSKeyValueObservation?
    private var detached: AVPlayer?
    private var bgObs: [NSObjectProtocol] = []
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        readyObs = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] l, _ in
            let r = l.isReadyForDisplay
            DispatchQueue.main.async { self?.onReadyForDisplay?(r) }
        }
        sizeObs = playerLayer.observe(\.videoRect, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.applyGravity() } }
        let nc = NotificationCenter.default
        bgObs = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard HGBackgroundPlayback.enabled, let self, self.pip?.active != true, let p = self.playerLayer.player else { return }
                    p.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
                    self.detached = p; self.playerLayer.player = nil
                }
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let p = self.detached else { return }
                    self.playerLayer.player = p; self.detached = nil
                }
            },
        ]
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { bgObs.forEach(NotificationCenter.default.removeObserver) }
    override func layoutSubviews() { super.layoutSubviews(); applyGravity() }
    func applyGravity() {
        guard let size = playerLayer.player?.currentItem?.presentationSize, size.width > 1, size.height > 1,
              bounds.width > 1, bounds.height > 1 else { return }
        let g: AVLayerVideoGravity = DYVideoFit.presentation(fillWidth: fillWidth, videoAspect: size.width / size.height,
                                                             screenAspect: bounds.width / bounds.height) == .aspectFill ? .resizeAspectFill : .resizeAspect
        if playerLayer.videoGravity != g { playerLayer.videoGravity = g }
    }
}

/// 普通 iPhone（非 Duo、非 iPad）的横竖屏：
/// - 播放页（推荐页 / 完整播放页）在屏上时跟着手机重力感应转（老板 2026-11-19：Air 上横过来不转）；
/// - 离开播放页回到发现 / 搜索 / 我的：锁回竖屏，并主动把界面转回来；
/// - 「更多 → 横屏 / 竖屏」仍可手动强制。
@MainActor enum HGOrientation {
    nonisolated(unsafe) static var allowLandscape = false
    /// 屏上的播放页个数（推荐流翻页时新旧两页会短暂同时在）
    private(set) static var players = 0
    nonisolated(unsafe) static var followsSensor = false
    static func playerAppeared() {
        players += 1
        followsSensor = true
        refresh()
    }
    static func playerDisappeared() {
        players = max(0, players - 1)
        // 翻页时旧页先 disappear、新页随后 appear：稍等再判断，避免中途锁回竖屏闪一下
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard players == 0 else { return }
            followsSensor = false
            allowLandscape = false
            refresh(forcePortrait: true)
        }
    }
    static func refresh(forcePortrait: Bool = false) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if forcePortrait, scene.effectiveGeometry.interfaceOrientation.isLandscape,
           UIDevice.current.userInterfaceIdiom == .phone, !DYDuoMetrics.isDuoHardware {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
}

enum HGBackgroundPlayback {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "hg.bgPlay.v2") }
}
