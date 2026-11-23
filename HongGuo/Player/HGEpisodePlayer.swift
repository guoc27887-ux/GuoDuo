import SwiftUI
import AVKit
import MediaPlayer
import Observation

struct HGPlayerRequest: Identifiable {
    let id = UUID()
    let series: HGSeries
    let episodes: [HGEpisode]
    let index: Int
    let startAt: Double
}

/// 一部剧的播放会话：当前集、预载、断点、倍速、弹幕、锁屏信息。
/// 只有一个 AVPlayer —— 竖滑翻页时换 item，避免多个解密文件同时占内存。
/// 音频会话全进程只激活一次
@MainActor enum HGAudioSession {
    private static var done = false
    static func activate() {
        guard !done else { return }
        done = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        HGAudioKeepAlive.start()
    }
    /// 退出 App（没开听书、没在画中画）：交还音频会话、清掉锁屏 / 灵动岛的「正在播放」，
    /// 否则系统会把刚暂停的会话当成还在放，灵动岛闪一下播放图标（老板 2026-11-19 反馈）
    static func releaseForBackground() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        HGAudioKeepAlive.release()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        done = false
    }
}

/// 静音保活：播放页在前台时常开一路全零音频，音频输出链路不断。
/// 真机（蓝牙耳机）实测 2026-11-24：AVPlayer 每换一集都要重新拉起蓝牙音频链路，画面等声音约 1.4 秒才动
/// （老板反馈「滑到下一集会暂停一会才播、推荐里卡很久」），挂上保活后切集起播 1.7 秒 → 0.5 秒。
/// 全零样本不出声，只多一点点耗电；退到后台（没开听书）随音频会话一起停。
@MainActor enum HGAudioKeepAlive {
    private static var engine: AVAudioEngine?
    private static var observers: [NSObjectProtocol] = []
    /// 只在前台保活：进后台一律停（听书模式下后台换集慢一点无所谓，不能让静音引擎把 App 一直吊在后台耗电）
    private static let lifecycle: [NSObjectProtocol] = {
        let nc = NotificationCenter.default
        return [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { stop() }
            },
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if wanted { start() } }
            },
        ]
    }()
    private static var wanted = false

    static func start() {
        _ = lifecycle
        wanted = true
        guard UIApplication.shared.applicationState != .background else { return }
        if let engine { if !engine.isRunning { try? engine.start() }; return }
        let e = AVAudioEngine()
        let fmt = e.outputNode.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return }
        let src = AVAudioSourceNode(format: fmt) { silence, _, _, abl in
            for b in UnsafeMutableAudioBufferListPointer(abl) { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
            silence.pointee = true
            return noErr
        }
        e.attach(src)
        e.connect(src, to: e.mainMixerNode, format: fmt)
        do { try e.start() } catch { return }
        engine = e
        let nc = NotificationCenter.default
        // 换耳机 / 来电打断后引擎会停：重新拉起（拔耳机等格式变化直接重建）
        observers = [
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { _ in
                MainActor.assumeIsolated { stop(); start() }
            },
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
                let ended = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
                MainActor.assumeIsolated { if ended, let engine, !engine.isRunning { try? engine.start() } }
            },
        ]
    }

    /// 交还音频会话时：停掉且回前台前不再自动拉起（等播放器重新 activate）
    static func release() { wanted = false; stop() }

    static func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine?.stop()
        engine = nil
    }
}

@MainActor @Observable
final class HGPlaybackSession {
    let series: HGSeries
    let episodes: [HGEpisode]
    private(set) var index: Int
    let player = AVPlayer()

    var status: String?
    var failed: String?
    var isPlaying = false
    var position: Double = 0
    var duration: Double = 0
    var videoAspect: Double = 9.0 / 16.0
    var danmaku: [DYDanmaku] = []
    var danmakuNotice: String?
    var clock = DYDanmakuClock()
    var lockedBoost = false
    /// 官方统计（App 详情接口）：本剧追剧数 / 播放量，每集评论数 / 点赞数
    var stats: HGSeriesStats?
    var seekPreviewImage: UIImage?
    private var imageGenerator: AVAssetImageGenerator?
    private var lastPreviewAt = Date.distantPast
    var boosting = false
    let pip = DYPictureInPicture()
    /// 环境光取帧输出：建 item 时（起播前）就挂上。起播后再给 item 加 VideoOutput 会让播放管线重建（画面顿一下、往前跳）
    private(set) var videoOutput: AVPlayerItemVideoOutput?

    private var startAt: Double
    private var loadTask: Task<Void, Never>?
    private var danmakuTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSaved = Date.distantPast
    private let library = HGLibrary.shared

    /// 推荐流：每部只放第 1 集；放完交给推荐流翻下一部，不记观看历史、不预载本剧第 2 集
    let feedMode: Bool
    var onFeedEnd: (() -> Void)?
    /// 推荐页被切走 / 推了详情：加载完成也先别出声
    private(set) var suspended = false
    /// 首帧已解好（预热完成或已开播）
    private(set) var frameReady = false
    /// 画面层已经出了本集第一帧（AVPlayerLayer.isReadyForDisplay）：之前一直盖着首帧海报，不黑屏
    private(set) var displayReady = false
    func setDisplayReady(_ r: Bool) { if displayReady != r { displayReady = r } }
    /// 后面几集的首帧（vid → 图）：滑动途中相邻页直接显示真画面，转正后第一帧解出来之前也先盖着它
    private(set) var posters: [String: UIImage] = [:]
    private var aheadTask: Task<Void, Never>?
    /// 往后预下几集：只备 1 集时连滑两下就得等下载
    private static let aheadCount = 2
    private var primeObs: NSKeyValueObservation?

    init(_ r: HGPlayerRequest, feedMode: Bool = false) {
        self.feedMode = feedMode
        series = r.series; episodes = r.episodes; index = r.index; startAt = r.startAt
        player.automaticallyWaitsToMinimizeStalling = false
        player.allowsExternalPlayback = true
        attachObservers()
    }
    private var bgObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var fgObserver: NSObjectProtocol?
    /// 失去前台那一刻因为要退出而先停的：没真进后台（只拉了控制中心 / 通知）就接着放
    private var pausedOnResign = false

    private func attachObservers() {
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.tick(t.seconds) }
            }
        }
        HGAudioSession.activate()
        // 预热中的（挂起）不抢锁屏 / 耳机按键，转正时 resumeIfSuspended 再挂
        if !suspended { setupRemoteCommands() }
        // scenePhase 在 fullScreenCover 里偶尔不回调：UIKit 通知兜底
        let nc = NotificationCenter.default
        if bgObserver == nil {
            bgObserver = nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !HGBackgroundPlayback.enabled, !self.pip.active, !self.pip.starting else { return }
                    self.pausedOnResign = false
                    self.pauseForBackground()
                    HGAudioSession.releaseForBackground()
                }
            }
        }
        // 退出就是退出：上滑回桌面的动画一开始（willResignActive）就停声音，不等动画放完才进后台
        // （之前在 didEnterBackground 才停，动画那半秒还在出声，灵动岛刷出播放图标）
        if resignObserver == nil {
            resignObserver = nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !HGBackgroundPlayback.enabled, !self.pip.active, !self.pip.starting,
                          !self.suspended, self.player.timeControlStatus != .paused else { return }
                    self.player.pause()
                    self.pausedOnResign = true
                }
            }
        }
        if activeObserver == nil {
            activeObserver = nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.pausedOnResign else { return }
                    self.pausedOnResign = false
                    // 只是拉了控制中心 / 来了通知横幅又回来：接着放
                    if !self.suspended, self.isPlaying { self.player.playImmediately(atRate: self.effectiveRate) }
                }
            }
        }
        if fgObserver == nil {
            fgObserver = nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HGAudioSession.activate() }
            }
        }
    }

    var episode: HGEpisode { episodes[index] }
    var title: String { "\(series.series_title) · 第 \(episode.number) 集" }
    var hasNext: Bool { index + 1 < episodes.count }
    var rate: Float { library.rate }
    var effectiveRate: Float { boosting || lockedBoost ? 2 : library.rate }

    private var started = false
    func start() {
        // 第二次 start（推荐页切 tab 回来）：从停下的位置接着放
        let resumeAt = started && position > 1 ? position : startAt
        if started { attachObservers() }
        started = true
        load(index, at: resumeAt)
        guard series.source == .hongguo else { return }
        let sid = series.series_id
        Task { [weak self] in self?.stats = try? await HGAPI.stats(series: sid) }
    }

    var episodeStat: HGEpisodeStat? { stats?.episodes.first { $0.vid == episode.vid } }

    /// 拖动进度时的预览画面（DouDuo 同款：节流 0.15 秒取一帧）。本地明文文件，取帧很快。
    func requestPreview(_ t: Double) {
        guard let gen = imageGenerator, Date().timeIntervalSince(lastPreviewAt) > 0.15 else { return }
        lastPreviewAt = Date()
        gen.cancelAllCGImageGeneration()
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: t, preferredTimescale: 600))]) { [weak self] _, cg, _, result, _ in
            guard result == .succeeded, let cg else { return }
            let img = UIImage(cgImage: cg)
            Task { @MainActor in self?.seekPreviewImage = img }
        }
    }
    func endPreview() { seekPreviewImage = nil }

    /// 截当前画面（原尺寸，精确到帧），本地明文文件直接取
    func snapshot() async -> UIImage? {
        guard let asset = player.currentItem?.asset else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let t = player.currentTime()
        guard let (cg, _) = try? await gen.image(at: t) else { return nil }
        return UIImage(cgImage: cg)
    }

    func go(to i: Int) {
        guard episodes.indices.contains(i), i != index else { return }
        save(force: true)
        lockedBoost = false
        load(i, at: 0)
    }
    func next() { if hasNext { go(to: index + 1) } }
    func previous() { if index > 0 { go(to: index - 1) } }

    func togglePlay() {
        if player.timeControlStatus == .paused { player.playImmediately(atRate: effectiveRate) } else { player.pause() }
        isPlaying = player.timeControlStatus != .paused
        clock.userToggle(position, playing: isPlaying, rate: Double(effectiveRate))
    }

    func seek(to t: Double) {
        let target = max(0, min(duration, t))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        position = target
        clock.seek(target, playing: isPlaying, rate: Double(effectiveRate))
    }

    func setRate(_ r: Float) {
        library.rate = r
        applyRate()
    }

    func setBoost(_ on: Bool) { boosting = on; applyRate() }
    func lockBoost() { lockedBoost = true; applyRate() }
    func unlockBoost() { lockedBoost = false; applyRate() }

    private func applyRate() {
        if player.timeControlStatus != .paused { player.rate = effectiveRate }
        clock.sync(position, playing: isPlaying, rate: Double(effectiveRate))
        updateNowPlaying()
    }

    func retry() { load(index, at: position) }

    func suspend() {
        suspended = true
        player.pause()
        isPlaying = false
        clock.userToggle(position, playing: false, rate: Double(effectiveRate))
    }

    /// 暂停的 AVPlayer 不会自己解第一帧：item 就绪后 preroll，滑过来直接是画面、马上能播
    private func prime(_ item: AVPlayerItem) {
        primeObs?.invalidate(); primeObs = nil
        let go: () -> Void = { [weak self] in
            guard let self, self.suspended, self.player.currentItem === item, self.player.rate == 0 else { return }
            // 不 preroll：真机实测 preroll 后起播，播到 1.25 秒必定跳回 0（预解的那段缓冲用完后管线重建）。
            // item 已 readyToPlay、画面层已挂上，起播只差解第一帧（几十毫秒）
            self.frameReady = true
        }
        if item.status == .readyToPlay { go(); return }
        primeObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard it.status == .readyToPlay else { return }
            Task { @MainActor in self?.primeObs?.invalidate(); self?.primeObs = nil; go() }
        }
    }

    func resumeIfSuspended() {
        guard suspended else { return }
        suspended = false
        setupRemoteCommands()   // 上一部 stop() 会清掉所有远程按键，前台这部重新挂上
        updateNowPlaying()
        guard player.currentItem != nil, failed == nil else { return }
        switchT0 = CACurrentMediaTime(); switchArmed = position < 0.05
        player.playImmediately(atRate: effectiveRate)
        isPlaying = true
        clock.userToggle(position, playing: true, rate: Double(effectiveRate))
    }

    /// 退出 App：没开听书模式、也不在画中画 → 停声音。回来不自动续播（和 DouDuo 一致，避免突然出声）。
    func pauseForBackground() {
        player.pause()
        isPlaying = false
        clock.userToggle(position, playing: false, rate: Double(effectiveRate))
        save(force: true)
    }

    func stop() {
        save(force: true)
        loadTask?.cancel(); danmakuTask?.cancel(); aheadTask?.cancel()
        primeObs?.invalidate(); primeObs = nil
        player.pause()
        if feedMode { player.replaceCurrentItem(with: nil) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        for o in [bgObserver, resignObserver, activeObserver, fgObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(o) }
        bgObserver = nil; resignObserver = nil; activeObserver = nil; fgObserver = nil
        if !suspended {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            let c = MPRemoteCommandCenter.shared()
            [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.nextTrackCommand, c.previousTrackCommand, c.changePlaybackPositionCommand]
                .forEach { $0.removeTarget(nil) }
        }
    }

    // MARK: 加载

    private var switchT0: CFTimeInterval = 0
    private var switchArmed = false
    private func load(_ i: Int, at offset: Double) {
        switchT0 = CACurrentMediaTime()
        loadTask?.cancel()
        index = i; failed = nil; status = "正在获取片源…"
        position = 0; duration = 0; danmaku = []; danmakuNotice = nil; frameReady = false; displayReady = false
        aheadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        clock = DYDanmakuClock()
        let vid = episodes[i].vid
        if episodes[i].locked == true {
            status = nil; failed = "本集在来源平台需要解锁，暂不能播放"
            if feedMode { onFeedEnd?() }
            return
        }
        startAtForDanmaku = offset
        loadDanmaku(vid)
        loadTask = Task { [weak self] in
            do {
                let file = try await HGMediaCache.shared.file(for: vid) { phase in
                    Task { @MainActor in
                        guard let self, self.index == i else { return }
                        switch phase {
                        case .resolving: self.status = "正在获取片源…"
                        case .downloading(let p): self.status = p > 0 ? "正在加载 \(Int(p * 100))%" : "正在加载…"
                        case .decrypting: self.status = "正在处理视频…"
                        }
                    }
                }
                guard let self, !Task.isCancelled, self.index == i else { return }
                self.attach(file, offset: offset)
                self.prefetchAhead(from: i)
            } catch {
                guard let self, !Task.isCancelled, self.index == i else { return }
                self.status = nil
                self.failed = error.localizedDescription
                // 推荐流：放不了的（只有 ByteVC2、要解锁、取源失败）直接跳下一部，不停在报错页
                if self.feedMode { self.onFeedEnd?() }
            }
        }
    }

    /// 预下后面几集 + 取首帧海报（推荐流每部只放第 1 集，不预下）
    private func prefetchAhead(from i: Int) {
        aheadTask?.cancel()
        guard !feedMode else { return }
        let vids = episodes.dropFirst(i + 1).prefix(Self.aheadCount).filter { $0.locked != true }.map(\.vid)
        let keep = Set([episodes[i].vid] + vids)
        posters = posters.filter { keep.contains($0.key) }
        aheadTask = Task { [weak self] in
            for vid in vids {
                // 取消只是不再等，缓存里的下载照常跑完
                guard let file = try? await HGMediaCache.shared.file(for: vid), !Task.isCancelled else { return }
                await self?.preparePoster(vid, file: file)
            }
        }
    }

    private func preparePoster(_ vid: String, file: URL) async {
        guard posters[vid] == nil else { return }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1080, height: 1080)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let (cg, _) = try? await gen.image(at: .zero), !Task.isCancelled else { return }
        posters[vid] = UIImage(cgImage: cg)
    }

    /// 弹幕：等本集时长出来后一次拉完整集（核心里按 30 秒窗 + cursor 续页，每页 200 条）。
    private var danmakuVid = ""
    private var startAtForDanmaku: Double = 0

    private func loadDanmaku(_ vid: String) {
        danmakuTask?.cancel()
        danmakuVid = vid
        guard series.source == .hongguo else { danmakuNotice = "该来源没有弹幕"; return }
        let sid = series.series_id
        danmakuTask = Task { [weak self] in
            // 时长：先等播放器给出（最多 8 秒），拿不到按 1 小时
            var dur = 0.0
            for _ in 0..<40 {
                guard let self, !Task.isCancelled else { return }
                if self.duration > 0 { dur = self.duration; break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let durationMs = dur > 0 ? Int(dur * 1000) + 1000 : 3_600_000
            do {
                let r = try await HGAPI.danmaku(series: sid, vid: vid, startMs: 0, durationMs: durationMs)
                guard let self, !Task.isCancelled, self.danmakuVid == vid else { return }
                self.danmaku = r.items
                self.danmakuNotice = r.items.isEmpty ? "本集暂无弹幕" : nil
            } catch {
                guard let self, !Task.isCancelled, self.danmakuVid == vid else { return }
                self.danmakuNotice = "弹幕源暂不可用"
            }
        }
    }

    private func attach(_ file: URL, offset: Double) {
        let item = AVPlayerItem(url: file)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        videoOutput = out
        item.audioTimePitchAlgorithm = .timeDomain
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.feedMode { self.isPlaying = false; self.onFeedEnd?(); return }
                if self.hasNext { self.next() } else { self.save(force: true, finished: true); self.isPlaying = false }
            }
        }
        player.replaceCurrentItem(with: item)
        switchArmed = !suspended   // 预热的（挂起）等转正时再计时
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 360, height: 360)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        imageGenerator = gen
        seekPreviewImage = nil
        Task { [weak self] in
            if let track = try? await AVURLAsset(url: file).loadTracks(withMediaType: .video).first,
               let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = size.applying(transform)
                if abs(r.height) > 1 { self?.videoAspect = Double(abs(r.width) / abs(r.height)) }
            }
        }
        if offset > 1 { player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        status = nil
        if suspended {
            isPlaying = false
            clock.seek(offset, playing: false, rate: Double(effectiveRate))
            prime(item)
        } else {
            player.playImmediately(atRate: effectiveRate)
            isPlaying = true
            clock.seek(offset, playing: true, rate: Double(effectiveRate))
        }
        save(force: true)
        updateNowPlaying()
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        if switchArmed && t > 0.05 {
            switchArmed = false
            HGTrace.log("\(feedMode ? "feed" : "full") ep\(index + 1) 起播 \(Int((CACurrentMediaTime() - switchT0) * 1000))ms")
        }
        if t > 0.05 && !frameReady { frameReady = true }
        position = t
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        isPlaying = player.timeControlStatus != .paused
        clock.sync(t, playing: isPlaying, rate: Double(player.rate > 0 ? player.rate : effectiveRate))
        save(force: false)
        if Int(t * 4) % 4 == 0 { updateNowPlaying() }
    }

    private func save(force: Bool, finished: Bool = false) {
        guard !feedMode else { return }
        guard force || Date().timeIntervalSince(lastSaved) > 5 else { return }
        lastSaved = Date()
        library.record(series, episode: index, position: finished ? 0 : (duration > 0 && position > duration - 2 ? 0 : position))
    }

    // MARK: 锁屏 / 控制中心

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.nextTrackCommand, c.previousTrackCommand, c.changePlaybackPositionCommand]
            .forEach { $0.removeTarget(nil) }
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.player.timeControlStatus == .paused { self?.togglePlay() } }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.player.timeControlStatus != .paused { self?.togglePlay() } }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlay() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if self?.feedMode == true { self?.onFeedEnd?() } else { self?.next() } }; return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard !suspended else { return }   // 预热中的别改锁屏信息
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "第 \(episode.number) 集",
            MPMediaItemPropertyAlbumTitle: series.series_title,
            MPMediaItemPropertyArtist: series.series_title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(effectiveRate) : 0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
