import SwiftUI
import UIKit

/// 关掉系统「点状态栏回到顶部」：在一集一页的竖滑播放里，这个手势会直接跳回第 1 集，
/// 看到哪集就丢了。SwiftUI 没开关，只能找到承载的 UIScrollView 把 scrollsToTop 关掉。
private struct HGScrollToTopDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: Probe, context: Context) { uiView.disable() }

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            disable()
        }

        func disable() {
            // 挂进层级后下一轮再找（首次布局时 superview 链可能还不完整）
            DispatchQueue.main.async { [weak self] in
                var p = self?.superview
                while let x = p, !(x is UIScrollView) { p = x.superview }
                (p as? UIScrollView)?.scrollsToTop = false
            }
        }
    }
}

extension View {
    /// 放在 ScrollView 的内容里用：关掉这个 ScrollView 的「点状态栏回顶部」。
    func hgDisableScrollToTop() -> some View {
        background(HGScrollToTopDisabler().frame(width: 0, height: 0))
    }
}
