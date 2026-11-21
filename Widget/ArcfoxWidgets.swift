import WidgetKit
import SwiftUI

/// 小组件数据源：从 App Group 读车况缓存（主 App / 刷新按钮负责拉新）。
struct CarEntry: TimelineEntry {
    let date: Date
    let cache: JSON?
    let session: Session
}

struct CarProvider: TimelineProvider {
    func placeholder(in context: Context) -> CarEntry {
        CarEntry(date: .now, cache: sampleCache(), session: Session.shared)
    }

    func getSnapshot(in context: Context, completion: @escaping (CarEntry) -> Void) {
        completion(CarEntry(date: .now, cache: TspControl.readCache() ?? sampleCache(), session: Session.shared))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CarEntry>) -> Void) {
        let entry = CarEntry(date: .now, cache: TspControl.readCache(), session: Session.shared)
        // 15 分钟后过期触发下一次 timeline 重建（配合 BGAppRefresh 的节奏）
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)!
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

// ---------------------------------------------------------------- 紧凑 4×2（medium）

struct CompactWidgetView: View {
    var entry: CarEntry
    @Environment(\.colorScheme) private var sysColor

    private var c: JSON? { entry.cache }

    private var radius: CGFloat { CGFloat(Store.getInt(Store.kWidgetRadius, 22)) }
    private var fontScale: CGFloat { CGFloat(Store.getInt(Store.kWidgetFontPct, 100)) / 100 }

    var body: some View {
        ZStack {
            ContainerRelativeShape()
                .fill(cardColor)
            if let img = carImage {
                HStack(spacing: 8) {
                    infoColumn
                    img.resizable().scaledToFit().frame(maxHeight: 74).frame(maxWidth: 110)
                }
                .padding(10)
            } else {
                infoColumn.padding(10)
            }
        }
        .widgetBackground(ContainerRelativeShape().fill(cardColor))
    }

    private var cardColor: Color {
        let alpha = Double(Store.getInt(Store.kWidgetAlpha, 100)) / 100
        let theme = Store.get(Store.kWidgetTheme, "auto")
        let dark = theme == "dark" || (theme == "auto" && sysColor == .dark)
        return dark ? Color(red: 0.10, green: 0.12, blue: 0.15).opacity(alpha)
                    : Color(red: 0.93, green: 0.95, blue: 0.97).opacity(alpha)
    }

    private var carImage: Image? {
        let group = CarModel.resolve(entry.session.modelCode, entry.session.vin, entry.session.model)
        if let ui = CarImages.load(CarModel.defaultCarImage(group)) {
            return Image(uiImage: ui)
        }
        return nil
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 4 * fontScale) {
            HStack {
                Text(title).font(.system(size: 12 * fontScale, weight: .semibold))
                Spacer()
                if c?.bool("charging", false) == true {
                    Image(systemName: "bolt.fill").font(.system(size: 11 * fontScale)).foregroundColor(.blue)
                }
            }
            HStack(spacing: 12 * fontScale) {
                stat(socText, "电量", socColor, size: 17)
                stat(rangeText, "续航", .primary, size: 14)
                stat(odoText, "里程", .primary, size: 14)
            }
            statLine(icon: "thermometer.medium", text: "车内 \(c?.string("temp") ?? "--")  车外 \(c?.string("out") ?? "--")")
            statLine(icon: "lock.\(locked == 1 ? "fill" : "open")", text: lockText, color: locked == 1 ? .primary : .orange)
            statLine(icon: "airbag", text: "胎压 \(c?.string("tyre") ?? "--/--/--/--")")
            if let loc = c?.string("loc"), !loc.isEmpty {
                Text(loc).font(.system(size: 9.5 * fontScale)).foregroundColor(.secondary).lineLimit(1)
            }
            Text(timeText).font(.system(size: 8.5 * fontScale)).foregroundColor(.secondary)
        }
    }

    private var title: String {
        let custom = Store.get(Store.kWidgetTitle)
        if !custom.isEmpty { return custom }
        let t = c?.string("title") ?? ""
        return t.isEmpty ? "极狐" : t
    }

    private var locked: Int {
        guard let c = c else { return -1 }
        if c.bool("lockKnown", false) || c.has("locked") {
            return c.bool("locked", false) ? 1 : 0
        }
        return -1
    }

    private var lockText: String {
        switch locked {
        case 1: return "已锁车" + (c?.bool("sentry", false) == true ? " · 哨兵开" : "")
        case 0: return "未锁车"
        default: return "门锁未知"
        }
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

    private func stat(_ v: String, _ label: String, _ color: Color, size: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(v).font(.system(size: size * fontScale, weight: .semibold, design: .rounded)).foregroundColor(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 8.5 * fontScale)).foregroundColor(.secondary)
        }
    }

    private func statLine(icon: String, text: String, color: Color = .primary) -> some View {
        HStack(spacing: 3 * fontScale) {
            Image(systemName: icon).font(.system(size: 9.5 * fontScale)).foregroundColor(.secondary)
            Text(text).font(.system(size: 9.5 * fontScale, weight: .medium)).foregroundColor(color).lineLimit(1)
        }
    }
}

struct CompactWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ArcfoxCompactWidget", provider: CarProvider()) { entry in
            CompactWidgetView(entry: entry)
        }
        .configurationDisplayName("极狐车况 · 紧凑")
        .description("车型 / 续航 / 电量 / 里程 / 内外温度 / 胎压 / 位置 + 车辆图")
        .supportedFamilies([.systemMedium])
    }
}

// ---------------------------------------------------------------- 带车控 4×4（large）

struct ControlWidgetView: View {
    var entry: CarEntry
    @Environment(\.colorScheme) private var sysColor

    private var c: JSON? { entry.cache }
    private var fontScale: CGFloat { CGFloat(Store.getInt(Store.kWidgetFontPct, 100)) / 100 }

    private var cardColor: Color {
        let alpha = Double(Store.getInt(Store.kWidgetAlpha, 100)) / 100
        let theme = Store.get(Store.kWidgetTheme, "auto")
        let dark = theme == "dark" || (theme == "auto" && sysColor == .dark)
        return dark ? Color(red: 0.10, green: 0.12, blue: 0.15).opacity(alpha)
                    : Color(red: 0.93, green: 0.95, blue: 0.97).opacity(alpha)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * fontScale) {
            HStack {
                VStack(alignment: .leading, spacing: 2 * fontScale) {
                    Text(entry.session.model.isEmpty ? (c?.string("title") ?? "我的极狐") : entry.session.model)
                        .font(.system(size: 15 * fontScale, weight: .semibold))
                    Text(c?.string("status") ?? "还没登录 / 授权")
                        .font(.system(size: 10 * fontScale)).foregroundColor(.secondary)
                }
                Spacer()
                RefreshButton()
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 14 * fontScale) {
                bigStat(c?.string("soc") ?? "--%", "电量", socColor, 30)
                bigStat(c?.string("range") ?? "--km", "续航", .primary, 22)
                bigStat(c?.string("odo") ?? "--", "里程", .primary, 22)
                bigStat(c?.string("temp") ?? "--", "车内温", .primary, 22)
            }
            if let loc = c?.string("loc"), !loc.isEmpty {
                Label(loc, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 10 * fontScale)).foregroundColor(.secondary).lineLimit(1)
            }
            HStack(spacing: 16 * fontScale) {
                statLine(icon: "airbag", text: "胎压 \(c?.string("tyre") ?? "--/--/--/--")")
                Spacer()
            }
            HStack(spacing: 10 * fontScale) {
                LockButton()
                    .buttonStyle(.borderless)
                AcButton()
                    .buttonStyle(.borderless)
                WindowButton()
                    .buttonStyle(.borderless)
                FindButton()
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .widgetBackground(ContainerRelativeShape().fill(cardColor))
    }

    private var socColor: Color {
        let s = (c?.string("soc") ?? "--").replacingOccurrences(of: "%", with: "")
        if let v = Int(s) {
            if v < 15 { return .red }
            if v < 40 { return .orange }
        }
        return .primary
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

struct ControlWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ArcfoxControlWidget", provider: CarProvider()) { entry in
            ControlWidgetView(entry: entry)
        }
        .configurationDisplayName("极狐车况 · 带车控")
        .description("解锁 / 空调 / 车窗 / 寻车四个车控入口 + 完整车况")
        .supportedFamilies([.systemLarge])
    }
}

// ---------------------------------------------------------------- 入口

@main
struct ArcfoxWidgetBundle: WidgetBundle {
    var body: some Widget {
        CompactWidget()
        ControlWidget()
    }
}
