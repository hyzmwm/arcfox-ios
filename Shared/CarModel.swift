import Foundation
import UIKit

/// 车型与车漆识别（对应 CarModel.java）：官方车型代号 > 车架号前 7 位 > 车型名。
enum CarModel {
    static let unknown = 0
    static let t5 = -1
    static let kaola = -2
    static let as = -3
    static let s5 = -4

    /// 车架号前缀表（全部取自官方公告与实车 VIN）
    static let vinTable: [(String, Int)] = [
        ("LNBMC1T", t5),
        ("LNBMC14", t5),
        ("LNBMC18", t5),
        ("LNBMC5G", kaola),
        ("LNBSC12", as),
        ("LNBSC13", as),
        ("LNBSC1L", as),
        ("LNBSC22", as),
        ("LNBSC24", s5),
    ]

    static func norm(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        if let cut = v.firstIndex(of: "_") {
            v = String(v[..<cut])
        }
        return v
    }

    static func byCode(_ code: String) -> Int {
        let c = norm(code)
        if c.isEmpty { return unknown }
        if c.hasPrefix("N50") { return t5 }
        if c.hasPrefix("N51") { return as }
        if c.hasPrefix("N61") { return s5 }
        if c.hasPrefix("A14") { return kaola }
        return unknown
    }

    static func byVin(_ vin: String) -> Int {
        let v = norm(vin)
        if v.count < 7 { return unknown }
        for (prefix, group) in vinTable where v.hasPrefix(prefix) {
            return group
        }
        return unknown
    }

    static func byName(_ name: String) -> Int {
        let m = norm(name)
        if m.isEmpty { return unknown }
        if m.contains("考拉") || m.contains("KAOLA") || m.contains("KOALA") { return kaola }
        if m.contains("S5") || m.contains("ΑS5") { return s5 }
        if m.contains("T5") || m.contains("ΑT5") { return t5 }
        if m.contains("阿尔法S") || m.contains("ALPHAS") || m.contains("ΑS") { return as }
        return unknown
    }

    /// 综合识别：官方车型代号 > 车架号 > 车型名
    static func resolve(_ modelCode: String, _ vin: String, _ modelName: String) -> Int {
        let code = byCode(modelCode)
        if code != unknown { return code }
        let byV = byVin(vin)
        if byV != unknown { return byV }
        return byName(modelName)
    }

    static func label(_ group: Int) -> String {
        switch group {
        case t5: return "阿尔法T5"
        case as: return "阿尔法S"
        case s5: return "阿尔法S5"
        case kaola: return "考拉"
        default: return "未识别"
        }
    }

    static func explain(_ modelCode: String, _ vin: String, _ modelName: String) -> String {
        let code = byCode(modelCode)
        let byV = byVin(vin)
        let v = norm(vin)
        let vinTxt = v.count >= 7 ? String(v.prefix(7)) + "***" : "（未取到）"
        if code != unknown {
            var extra = ""
            if byV != unknown && byV != code {
                extra = "（车架号看着像 \(label(byV))，仍以官方代号为准）"
            }
            return "车型代号 \(modelCode.trimmingCharacters(in: .whitespaces)) → \(label(code))\(extra)"
        }
        if byV != unknown { return "车架号 \(vinTxt) → \(label(byV))" }
        if byName(modelName) != unknown {
            return "车型名「\(modelName.trimmingCharacters(in: .whitespaces))」→ \(label(byName(modelName)))"
        }
        return "未识别（刷新一次车况再试）"
    }

    static func groupOfKey(_ key: String) -> Int {
        switch key.trimmingCharacters(in: .whitespaces).lowercased() {
        case "t5", "t5_real": return t5
        case "kaola": return kaola
        case "alpha_s", "as": return as
        case "s5": return s5
        default: return unknown
        }
    }

    /// 车型组 → 内置官方整车图文件名
    static func defaultCarImage(_ group: Int) -> String {
        switch group {
        case s5: return "car_s5_nce"
        case as: return "car_as_white"
        case kaola: return "car_kaola_official"
        default: return "car_t5_caw"
        }
    }
}

/// 车图加载：内置官方图 + 用户自定义图（存 App Group 容器，App 与小组件共用）。
enum CarImages {
    static let customPath: URL = {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Store.appGroupId)
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("car_custom.png")
    }()

    static func hasCustom() -> Bool {
        FileManager.default.fileExists(atPath: customPath.path)
    }

    static func saveCustom(_ image: UIImage) {
        // 压到 448px 窄边以内再存（对应 Android 版「窄边压到 448px、PNG 二压后存私有目录」）
        let scale = min(1.0, 448.0 / max(image.size.width, image.size.height))
        let target = CGSize(image.size.width * scale, image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let out = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if let data = out.pngData() {
            try? data.write(to: customPath, options: .atomic)
        }
        WidgetBridge.reloadWidgets()
    }

    static func clearCustom() {
        try? FileManager.default.removeItem(at: customPath)
        WidgetBridge.reloadWidgets()
    }

    static func load(_ name: String) -> UIImage? {
        if hasCustom(), let img = UIImage(contentsOfFile: customPath.path) { return img }
        // 先找 bundle 里的车图（两个 target 都带 Resources/CarImages）
        if let img = UIImage(named: name) { return img }
        if let path = Bundle.main.path(forResource: name, ofType: "png", inDirectory: nil),
           let img = UIImage(contentsOfFile: path) {
            return img
        }
        return nil
    }
}

import CoreGraphics
private extension CGSize {
    init(_ w: CGFloat, _ h: CGFloat) {
        self.init(width: w, height: h)
    }
}
