import AppIntents
import WidgetKit
import SwiftUI

// iOS 17 交互式小组件按钮：每个 Intent 的 perform() 直接在扩展进程里跑控车/刷新，
// 完成后 reloadAllTimelines 让卡片立刻反映最新状态。

struct RefreshIntent: AppIntent {
    static let title: LocalizedStringResource = "刷新车况"
    static let description = IntentDescription("重新拉取极狐车况")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        var r = Fetcher.fetch()
        if r.cache == nil {
            // 共享通道没数据 → 云同步兼底后重试
            let code = Store.get(Store.kCloudTopic)
            if !code.isEmpty {
                CloudSync.download(code: code)
                r = Fetcher.fetch()
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        if let c = r.cache {
            Store.set(Store.kCache, c.rawUnsorted)
            return .result(dialog: IntentDialog(stringLiteral: "已刷新 · " + (c.string("soc")) + " " + (c.string("range"))))
        }
        return .result(dialog: IntentDialog(stringLiteral: r.error ?? "刷新失败"))
    }
}

// iOS 17 小组件配置：同步码（App 高级设置·云同步里查看/复制）
struct SyncConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "极狐车况配置"
    static let description = IntentDescription("无共享权限时填同步码，小组件改走云端拉车况")

    @Parameter(title: "同步码", description: "在极狐车况App·高级设置·云同步里复制", default: "")
    var syncCode: String
}

struct LockToggleIntent: AppIntent {
    static let title: LocalizedStringResource = "锁车 / 解锁"
    static let description = IntentDescription("切换车门锁状态")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let held = TspControl.heldLock()
        let locked = held >= 0 ? held == 1 : (TspControl.readCache()?.bool("locked", false) ?? false)
        let r = TspControl.setDoor(!locked)
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: IntentDialog(stringLiteral: r.msg))
    }
}

struct AcToggleIntent: AppIntent {
    static let title: LocalizedStringResource = "空调开关"
    static let description = IntentDescription("开 / 关空调")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = TspControl.toggle()
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: IntentDialog(stringLiteral: r.msg))
    }
}

struct WindowToggleIntent: AppIntent {
    static let title: LocalizedStringResource = "车窗开关"
    static let description = IntentDescription("开 / 关车窗")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = TspControl.toggleWindow()
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: IntentDialog(stringLiteral: r.msg))
    }
}

struct FindCarIntent: AppIntent {
    static let title: LocalizedStringResource = "寻车"
    static let description = IntentDescription("鸣笛闪灯寻车")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = TspControl.find()
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: IntentDialog(stringLiteral: r.msg))
    }
}

// ---------------------------------------------------------------- 按钮 View

struct RefreshButton: View {
    var body: some View {
        Button(intent: RefreshIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .padding(6)
                .background(Circle().fill(.secondary.opacity(0.25)))
        }
    }
}

struct LockButton: View {
    var body: some View {
        Button(intent: LockToggleIntent()) {
            VStack(spacing: 3) {
                Image(systemName: "lock.fill").font(.system(size: 16))
                Text("锁车").font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.18)))
        }
    }
}

struct AcButton: View {
    var body: some View {
        Button(intent: AcToggleIntent()) {
            VStack(spacing: 3) {
                Image(systemName: "fanblades.fill").font(.system(size: 16))
                Text("空调").font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.18)))
        }
    }
}

struct WindowButton: View {
    var body: some View {
        Button(intent: WindowToggleIntent()) {
            VStack(spacing: 3) {
                Image(systemName: "rectangle.split.3x1").font(.system(size: 16))
                Text("车窗").font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.18)))
        }
    }
}

struct FindButton: View {
    var body: some View {
        Button(intent: FindCarIntent()) {
            VStack(spacing: 3) {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 16))
                Text("寻车").font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.18)))
        }
    }
}
