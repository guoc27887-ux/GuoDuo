// iOS 18 移植垫片（SDK 27 shims）
//
// 上游按 iOS 27 SDK 编写；GitHub 的 macos-26 runner 只有 iOS 26 SDK，
// 一批 iOS 27 独占符号在编译期不存在，光靠源码里的 #available 运行时守卫救不了。
// 本文件在同一模块内补上 GuoDuo 实际用到的这批符号的空实现，语义统一为「普通 iPhone」：
//   - iPhone 不是折叠屏：没有铰链、没有 division / occlusion 保留区；
//   - iPhone 没有竖排工具栏：竖排行为一律透传走系统默认。
// 所有调用点本来就被 #available(iOS 27.x) 守卫或在无铰链时走同一条回退路径，
// 所以在 iPhone 上与原版行为等价，不是砍功能。
//
// ⚠️ 若将来改用 iOS 27 SDK 编译，本文件会与系统符号重名，届时应整文件删除。
import SwiftUI

// MARK: - GeometryProxy.reservedRegions（折痕 / 遮挡保留区）

/// 保留区类别垫片（对应 iOS 27 的 reserved-region kind）。
enum HGReservedRegionKind {
    case division
    case occlusion
}

/// 保留区布局方向行为垫片。
enum HGReservedRegionLayoutDirectionBehavior {
    case fixed
    case mirrored
}

/// 保留区元素垫片：只补上游实际读取的 frame / isActive 两个字段。
struct HGReservedRegion {
    var frame: CGRect = .zero
    var isActive: Bool = false
}

extension GeometryProxy {
    /// iPhone 无折痕、无系统保留区：恒返回空数组。
    /// 上游拿到空数组后的处理（不分屏、不平移、遮挡内边距为 0）正是普通手机应有的结果。
    func reservedRegions(kind: HGReservedRegionKind,
                         layoutDirectionBehavior: HGReservedRegionLayoutDirectionBehavior = .fixed) -> [HGReservedRegion] {
        []
    }
}

// MARK: - DeviceHinge / View.onHingeChange（铰链状态）

/// 铰链垫片（对应 iOS 27 的 DeviceHinge）。iPhone 没有铰链，
/// 本类型永远不会产生实例：onHingeChange 垫片不回调、context.hinge 恒为 nil，
/// 调用方一律走「不支持折叠」路径。
struct DeviceHinge {
    enum Status {
        case closed
        case partiallyOpen
        case fullyOpen
    }
    var status: Status
}

/// onHingeChange 回调上下文垫片：只补调用方实际读取的 hinge 字段。
struct HGHingeChangeContext {
    var hinge: DeviceHinge? = nil
}

extension View {
    /// 无铰链设备上永不触发：直接透传，不挂任何监听。
    func onHingeChange(perform action: @escaping (DeviceHinge?, HGHingeChangeContext) -> Void) -> Self {
        self
    }
}

// MARK: - ToolbarPlacement.statusBar

extension ToolbarPlacement {
    /// iOS 27 的状态栏工具栏位置在 iOS 26 SDK 里不存在：回退 .automatic。
    /// 唯一调用点在 #available(iOS 27.0) 守卫内（评论栏状态栏显隐），
    /// iOS 18 设备上不会执行到；仅在 iOS 27 设备上跑这个包时，
    /// 状态栏显隐会作用到 automatic 位置，与原意略有出入。
    static var statusBar: ToolbarPlacement { .automatic }
}

// MARK: - 工具栏竖排行为（透传走默认）

/// 对应 iOS 27 的 toolbarVerticalBehavior 参数。
enum HGToolbarVerticalBehavior {
    case automatic
    case disabled
}

extension View {
    /// iPhone 没有竖排工具栏，竖排行为无从谈起：透传。
    func toolbarVerticalBehavior(_ behavior: HGToolbarVerticalBehavior) -> Self { self }
}
