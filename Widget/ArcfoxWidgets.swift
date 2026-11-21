import WidgetKit
import SwiftUI
import UIKit

/// 小组件数据源：从 App Group 读车况缓存（主 App / 刷新按钮负责拉新）。
struct CarEntry: TimelineEntry {
    let date: Date
    let cache: JSON?
    let session: Session
    var fetchError: String = ""
    var groupOk: Bool = true
}

struct CarProvider: TimelineProvider {
    func placeholder(in context: Context) -> CarEntry {
        CarEntry(date: .now, cache: sampleCache(), session: Session.shared)
    }

    func getSnapshot(in context: Context, completion: @escaping (CarEntry) -> Void) {
        completion(CarEntry(date: .now, cache: TspControl.readCache() ?? sampleCache(), session: Session.shared))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CarEntry>) -> Void) {
        // ① 先读共享缓存；② 为空或过期则扩展进程自取（token 同样来自共享存储）
        var cache = TspControl.readCache()
        var fetchError = ""
        let autoMin = max(Store.getInt(Store.kAutoMin, 15), 5)
        let ts = Store.getLong(Store.kCacheTs, 0)
        let stale = ts == 0 || Date().timeIntervalSince1970 * 1000 - Double(ts) > Double(autoMin) * 60_000
        if cache == nil || stale {
            let r = Fetcher.fetch()
            if let c = r.cache {
                TspControl.reconcile(c)
                Store.set(Store.kCache, c.rawUnsorted)
                Store.setLong(Store.kCacheTs, Int64(Date().timeIntervalSince1970 * 1000))
                cache = c
            } else {
                fetchError = r.error ?? "取不到车况"
            }
        }
        let groupOk = Store.probeGroup()
        let entry = CarEntry(date: .now, cache: cache, session: Session.shared,
                             fetchError: fetchError, groupOk: groupOk)
        // 15 分钟后过期触发下一次 timeline 重建（配合 BGAppRefresh 的节奏）
        let next = Calendar.current.date(byAdding: .minute, value: autoMin, to: entry.date)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func sampleCache() -> JSON {
        JSON([
            "title": "我的极狐", "soc": "82%", "range": "486 km", "odo": "12345 km",
            "temp": "22.5℃", "out": "18.0℃", "tyre": "2.40/2.40/2.40/2.40",
            "loc": "车辆未上报位置", "status": "已锁车", "locked": true, "lockKnown": true,
            "ac": 0, "acKnown": true, "win": 0, "winKnown": true, "charging": false,
            "dataTs": "12:30", "ts": "12:35",
        ])
    }
}

// ---------------------------------------------------------------- 通用

/// 卡片底色（跟随主题/透明度设置）
private func cardBackground(_ sysColor: ColorScheme) -> Color {
    let alpha = Double(Store.getInt(Store.kWidgetAlpha, 100)) / 100
    let theme = Store.get(Store.kWidgetTheme, "auto")
    let dark = theme == "dark" || (theme == "auto" && sysColor == .dark)
    return dark ? Color(red: 0.10, green: 0.12, blue: 0.15).opacity(alpha)
                : Color(red: 0.93, green: 0.95, blue: 0.97).opacity(alpha)
}

/// 中号里的图标式控车按钮（iOS 17 交互式，点击直接在扩展进程执行）。
struct IconCtrlButton: View {
    enum Kind { case lock, ac, window, find }
    let kind: Kind
    var scale: CGFloat = 1

    var body: some View {
        switch kind {
        case .lock:
            Button(intent: LockToggleIntent()) { label(locked == 1 ? "lock.fill" : "lock.open", locked == 1 ? "已锁" : "未锁") }
        case .ac:
            Button(intent: AcToggleIntent()) { label("fanblades.fill", "空调") }
        case .window:
            Button(intent: WindowToggleIntent()) { label("rectangle.split.3x1", "车窗") }
        case .find:
            Button(intent: FindCarIntent()) { label("iphone.radiowaves.left.and.right", "寻车") }
        }
    }

    private var locked: Int {
        let held = TspControl.heldLock()
        if held >= 0 { return held }
        guard let c = TspControl.readCache() else { return -1 }
        if c.bool("lockKnown", false) || c.has("locked") { return c.bool("locked", false) ? 1 : 0 }
        return -1
    }

    private func label(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3 * scale) {
            Image(systemName: icon).font(.system(size: 11 * scale, weight: .semibold))
            Text(text).font(.system(size: 10 * scale, weight: .medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5 * scale)
        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.20)))
    }
}

// ---------------------------------------------------------------- 中号：紧凑 + 控车

struct CompactWidgetView: View {
    var entry: CarEntry
    @Environment(\.colorScheme) private var sysColor

    private var c: JSON? { entry.cache }
    private var fontScale: CGFloat { CGFloat(Store.getInt(Store.kWidgetFontPct, 100)) / 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * fontScale) {
            // 标题行
            HStack(spacing: 5 * fontScale) {
                Text(title).font(.system(size: 13 * fontScale, weight: .semibold)).lineLimit(1)
                if c?.bool("charging", false) == true {
                    Image(systemName: "bolt.fill").font(.system(size: 10 * fontScale)).foregroundColor(.blue)
                }
                if sentry {
                    Image(systemName: "eye.fill").font(.system(size: 10 * fontScale)).foregroundColor(.orange)
                }
                Spacer(minLength: 0)
                if entry.cache == nil {
                    Text("无数据").font(.system(size: 9)).foregroundColor(.orange)
                }
            }

            HStack(alignment: .center, spacing: 8 * fontScale) {
                VStack(alignment: .leading, spacing: 4 * fontScale) {
                    HStack(spacing: 12 * fontScale) {
                        stat(socText, "电量", socColor, size: 20)
                        stat(rangeText, "续航", .primary, size: 15)
                        stat(odoText, "里程", .primary, size: 13)
                    }
                    HStack(spacing: 8 * fontScale) {
                        statLine(icon: "thermometer.medium", text: "\(c?.string("temp") ?? "--")/\(c?.string("out") ?? "--")")
                        statLine(icon: "airbag", text: c?.string("tyre") ?? "--")
                    }
                }
                Spacer(minLength: 0)
                if let img = carImage {
                    img.resizable().scaledToFit().frame(maxHeight: 52 * fontScale).frame(maxWidth: 96)
                }
            }

            // 控车按钮行
            HStack(spacing: 6 * fontScale) {
                IconCtrlButton(kind: .lock, scale: fontScale)
                IconCtrlButton(kind: .ac, scale: fontScale)
                IconCtrlButton(kind: .window, scale: fontScale)
                IconCtrlButton(kind: .find, scale: fontScale)
                Button(intent: RefreshIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11 * fontScale, weight: .semibold))
                        .padding(.vertical, 5 * fontScale)
                        .padding(.horizontal, 7 * fontScale)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.20)))
                }
            }

            HStack(spacing: 4 * fontScale) {
                if entry.cache == nil {
                    Text(hintText)
                        .font(.system(size: 8.5 * fontScale, weight: .medium))
                        .foregroundColor(.orange)
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Image(systemName: locked == 1 ? "lock.fill" : "lock.open")
                        .font(.system(size: 8.5 * fontScale))
                        .foregroundColor(locked == 1 ? .secondary : .orange)
                    Text(lockText).font(.system(size: 8.5 * fontScale)).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Text(timeText).font(.system(size: 8.5 * fontScale)).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
        .padding(11)
        .containerBackground(for: .widget) { ContainerRelativeShape().fill(cardBackground(sysColor)) }
    }

    private var title: String {
        let custom = Store.get(Store.kWidgetTitle)
        if !custom.isEmpty { return custom }
        let t = c?.string("title") ?? ""
        return t.isEmpty ? "极狐" : t
    }

    private var locked: Int {
        let held = TspControl.heldLock()
        if held >= 0 { return held }
        guard let c = c else { return -1 }
        if c.bool("lockKnown", false) || c.has("locked") { return c.bool("locked", false) ? 1 : 0 }
        return -1
    }

    private var lockText: String {
        switch locked {
        case 1: return "已锁车"
        case 0: return "未锁车"
        default: return "门锁未知"
        }
    }

    private var sentry: Bool { c?.bool("sentry", false) ?? false }

    private var hintText: String {
        if !entry.groupOk { return "共享存储异常 · 需 TrollStore 环境重装" }
        if !entry.fetchError.isEmpty { return "自取失败：\(entry.fetchError)" }
        return "请打开极狐车况 App 下拉刷新一次"
    }

    private var socText: String { c?.string("soc") ?? "--%" }
    private var rangeText: String { c?.string("range") ?? "--km" }
    private var odoText: String { c?.string("odo") ?? "--" }

    private var socColor: Color {
        let s = socText.replacingOccurrences(of: "%", with: "")
        if let v = Int(s) {
            if v < 15 { return .red }
            if v < 40 { return .orange }
        }
        return .primary
    }

    private var timeText: String {
        var t = "更新 " + (c?.string("ts") ?? "--")
        if let d = c?.string("dataTs"), !d.isEmpty { t = "数据 \(d) · \(c?.string("ts") ?? "--")" }
        return t
    }

    private var carImage: Image? {
        let group = CarModel.resolve(entry.session.modelCode, entry.session.vin, entry.session.model)
        if let ui = CarImages.load(CarModel.defaultCarImage(group)) {
            return Image(uiImage: ui)
        }
        return nil
    }

    private func stat(_ v: String, _ label: String, _ color: Color, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.system(size: size * fontScale, weight: .semibold, design: .rounded)).foregroundColor(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 8.5 * fontScale)).foregroundColor(.secondary)
        }
    }

    private func statLine(icon: String, text: String) -> some View {
        HStack(spacing: 3 * fontScale) {
            Image(systemName: icon).font(.system(size: 8.5 * fontScale)).foregroundColor(.secondary)
            Text(text).font(.system(size: 9 * fontScale, weight: .medium)).lineLimit(1)
        }
    }
}

// ---------------------------------------------------------------- 大号：完整车况 + 车控面板

struct ControlWidgetView: View {
    var entry: CarEntry
    @Environment(\.colorScheme) private var sysColor

    private var c: JSON? { entry.cache }
    private var fontScale: CGFloat { CGFloat(Store.getInt(Store.kWidgetFontPct, 100)) / 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * fontScale) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2 * fontScale) {
                    Text(entry.session.model.isEmpty ? (c?.string("title") ?? "我的极狐") : entry.session.model)
                        .font(.system(size: 15 * fontScale, weight: .semibold)).lineLimit(1)
                    Text(c?.string("status") ?? "还没登录 / 授权")
                        .font(.system(size: 10 * fontScale)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let img = carImage {
                    img.resizable().scaledToFit().frame(maxHeight: 30 * fontScale).frame(maxWidth: 92)
                }
                Button(intent: RefreshIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12 * fontScale, weight: .semibold))
                        .padding(6)
                        .background(Circle().fill(.secondary.opacity(0.20)))
                }
            }

            HStack(spacing: 14 * fontScale) {
                bigStat(c?.string("soc") ?? "--%", "电量", socColor, 30)
                bigStat(c?.string("range") ?? "--km", "续航", .primary, 22)
                bigStat(c?.string("odo") ?? "--", "里程", .primary, 22)
                bigStat(c?.string("temp") ?? "--", "车内温", .primary, 20)
                bigStat(c?.string("out") ?? "--", "车外温", .primary, 20)
            }

            if entry.cache == nil {
                Text(hintText)
                    .font(.system(size: 10 * fontScale, weight: .medium)).foregroundColor(.orange)
                    .lineLimit(2)
            }

            // 状态胶囊
            HStack(spacing: 6 * fontScale) {
                pill(locked == 1 ? "lock.fill" : "lock.open", lockText, locked == 1 ? .green : .orange)
                pill("fanblades", acText, acOn ? .blue : .secondary)
                pill("rectangle.split.3x1", winText, winOn ? .blue : .secondary)
                pill(sentry ? "eye.fill" : "eye", sentry ? "哨兵开" : "哨兵关", sentry ? .orange : .secondary)
                if c?.bool("charging", false) == true { pill("bolt.fill", "充电中", .blue) }
            }

            if let loc = c?.string("loc"), !loc.isEmpty {
                Label(loc, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 10 * fontScale)).foregroundColor(.secondary).lineLimit(1)
            }
            HStack(spacing: 14 * fontScale) {
                statLine(icon: "airbag", text: "胎压 \(c?.string("tyre") ?? "--/--/--/--")")
                Spacer(minLength: 0)
                Text(timeText).font(.system(size: 9 * fontScale)).foregroundColor(.secondary).lineLimit(1)
            }

            Spacer(minLength: 2)

            HStack(spacing: 8 * fontScale) {
                LockButton()
                AcButton()
                WindowButton()
                FindButton()
            }
        }
        .padding(14)
        .containerBackground(for: .widget) { ContainerRelativeShape().fill(cardBackground(sysColor)) }
    }

    private var hintText: String {
        if !entry.groupOk { return "共享存储异常 · 需 TrollStore 环境重装" }
        if !entry.fetchError.isEmpty { return "自取失败：\(entry.fetchError)" }
        return "请打开极狐车况 App 下拉刷新一次"
    }

    private var locked: Int {
        let held = TspControl.heldLock()
        if held >= 0 { return held }
        guard let c = c else { return -1 }
        if c.bool("lockKnown", false) || c.has("locked") { return c.bool("locked", false) ? 1 : 0 }
        return -1
    }

    private var lockText: String {
        switch locked {
        case 1: return "已锁车"
        case 0: return "未锁车"
        default: return "门锁未知"
        }
    }

    private var acOn: Bool { c?.bool("ac", false) ?? false }
    private var acText: String { c == nil ? "空调未知" : (acOn ? "空调开" : "空调关") }

    private var winOn: Bool { (c?.int("win", 0) ?? 0) > 0 }
    private var winText: String {
        if c == nil { return "车窗未知" }
        if !(c?.bool("winKnown", false) ?? false) { return "车窗未知" }
        return winOn ? "车窗开" : "车窗关"
    }

    private var sentry: Bool { c?.bool("sentry", false) ?? false }

    private var timeText: String {
        var t = "更新 " + (c?.string("ts") ?? "--")
        if let d = c?.string("dataTs"), !d.isEmpty { t = "数据 \(d) · \(c?.string("ts") ?? "--")" }
        return t
    }

    private var socColor: Color {
        let s = (c?.string("soc") ?? "--").replacingOccurrences(of: "%", with: "")
        if let v = Int(s) {
            if v < 15 { return .red }
            if v < 40 { return .orange }
        }
        return .primary
    }

    private var carImage: Image? {
        let group = CarModel.resolve(entry.session.modelCode, entry.session.vin, entry.session.model)
        if let ui = CarImages.load(CarModel.defaultCarImage(group)) {
            return Image(uiImage: ui)
        }
        return nil
    }

    private func pill(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3 * fontScale) {
            Image(systemName: icon).font(.system(size: 9 * fontScale))
            Text(text).font(.system(size: 9 * fontScale, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(color)
        .padding(.horizontal, 6 * fontScale)
        .padding(.vertical, 3 * fontScale)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private func bigStat(_ v: String, _ label: String, _ color: Color, _ size: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: size * fontScale, weight: .semibold, design: .rounded)).foregroundColor(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 9 * fontScale)).foregroundColor(.secondary)
        }
    }

    private func statLine(icon: String, text: String) -> some View {
        HStack(spacing: 3 * fontScale) {
            Image(systemName: icon).font(.system(size: 9.5 * fontScale)).foregroundColor(.secondary)
            Text(text).font(.system(size: 9.5 * fontScale)).foregroundColor(.primary).lineLimit(1)
        }
    }
}

// ---------------------------------------------------------------- 入口（一个小组件，中/大两种尺寸）

struct ArcfoxWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: CarEntry

    var body: some View {
        if family == .systemLarge {
            ControlWidgetView(entry: entry)
        } else {
            CompactWidgetView(entry: entry)
        }
    }
}

struct ArcfoxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ArcfoxCompactWidget", provider: CarProvider()) { entry in
            ArcfoxWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("极狐车况")
        .description("中号：车况 + 一键控车；大号：完整车况 + 车控面板（长按可切换尺寸）")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct ArcfoxWidgetBundle: WidgetBundle {
    var body: some Widget {
        ArcfoxWidget()
    }
}
