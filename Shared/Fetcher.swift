import Foundation
import WidgetKit

/// JSON 宽松取值（对应 JsonProbe.java）
enum JsonProbe {
    static func findNumber(_ node: Any?, _ keys: String...) -> Double? {
        guard let found = find(node, keys) else { return nil }
        if let n = found as? NSNumber { return n.doubleValue }
        if let b = found as? Bool { return b ? 1 : 0 }
        return parseNumber(String(describing: found))
    }

    private static func find(_ node: Any?, _ keys: [String]) -> Any? {
        guard let node = node else { return nil }
        if let o = node as? [String: Any] {
            for k in keys {
                if let mk = matchKey(o, k), let v = o[mk], !(v is [String: Any]), !(v is [Any]) {
                    return v
                }
            }
            // 插入顺序不可控，按原 key 遍历递归（行为与 Java 端一致：递归找第一个命中）
            for (_, v) in o {
                if let r = find(v, keys) { return r }
            }
            return nil
        }
        if let arr = node as? [Any] {
            for v in arr {
                if let r = find(v, keys) { return r }
            }
        }
        return nil
    }

    private static func matchKey(_ o: [String: Any], _ k: String) -> String? {
        if o[k] != nil { return k }
        let want = norm(k)
        for key in o.keys where norm(key) == want { return key }
        return nil
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    }

    static func parseNumber(_ s: String?) -> Double? {
        guard let s = s else { return nil }
        var sb = ""
        var dot = false
        for c in s {
            if c.isNumber {
                sb.append(c)
            } else if (c == "." || c == ",") && !dot {
                sb.append(".")
                dot = true
            } else if c == "-" && sb.isEmpty {
                sb.append(c)
            }
        }
        if sb.isEmpty || sb == "-" || sb == "." { return nil }
        return Double(sb)
    }
}

/// 车况拉取与解析（对应 Fetcher.java）
enum Fetcher {

    struct Result {
        var cache: JSON?
        var error: String?
        var needLogin = false
        var raw = ""
        var code = -1
        var source = ""
    }

    static func fetch() -> Result {
        var r = fetchInner()
        if let c = r.cache { attachLocation(c) }
        return r
    }

    static func attachLocation(_ cache: JSON) {
        let lat = cache.double("lat")
        let lon = cache.double("lon")
        if let la = lat, let lo = lon {
            let loc = Geo.describe(la, lo)
            var o = cache.obj
            o["loc"] = loc
            cache.obj = o
        } else {
            var o = cache.obj
            o["loc"] = "车辆未上报位置"
            cache.obj = o
        }
    }

    private static func fetchInner() -> Result {
        let s = Session.shared
        if !s.vin.isEmpty && (!s.tspToken.isEmpty || !s.refreshToken.isEmpty) {
            return fetchTsp(s)
        }
        var r = Result()
        r.error = s.loggedIn ? "尚未完成车况授权（缺少 VIN 或 token）" : "还没登录极狐账号"
        r.needLogin = true
        return r
    }

    private static func fetchTsp(_ s: Session) -> Result {
        var r = Result()
        r.source = "tsptoken"
        if !s.ensureToken() {
            r.error = "车况 token 已失效，需要重新授权"
            r.needLogin = true
            return r
        }
        var resp = ArcApi.carGet(ArcApi.carStatePath(s.vin), s.tspToken)
        r.code = resp.http
        r.raw = resp.body
        if expired(resp) && s.refresh().bizOk {
            resp = ArcApi.carGet(ArcApi.carStatePath(s.vin), s.tspToken)
            r.code = resp.http
            r.raw = resp.body
        }
        if expired(resp) {
            r.error = "车况 token 过期且续期失败，请重新走一次车况授权（会再收一条短信）"
            r.needLogin = true
            return r
        }
        if let e = resp.error {
            r.error = e
            return r
        }
        if !resp.bizOk {
            r.error = resp.describe
            return r
        }
        let cond = fetchCondition(s)
        r.cache = parse(resp.json, s.model, s.plate, cond, TspControl.heldLock())
        if r.cache != nil {
            var o = r.cache!.obj
            o["modelCode"] = s.modelCode
            r.cache!.obj = o

            // 车型代号 / 车漆颜色缺项时补拉 getDefaultVehicle（5 分钟节流；否则 1 小时）
            let needCode = s.modelCode.isEmpty
            let needColor = Store.get(Store.kCarColorName).isEmpty
            let lastTry = Store.getLong(Store.kVehicleTs, 0)
            let wait: Int64 = (needCode || needColor) ? 300_000 : 3_600_000
            let cooled = Int64(Date().timeIntervalSince1970 * 1000) - lastTry > wait
            if (needCode || needColor) && cooled && !s.mainToken.isEmpty {
                Store.setLong(Store.kVehicleTs, Int64(Date().timeIntervalSince1970 * 1000))
                let before = Store.get(Store.kCarColorName)
                if s.loadVehicle().bizOk {
                    let after = Store.get(Store.kCarColorName)
                    if after != before {
                        WidgetBridge.reloadWidgets()
                    }
                }
            }
        }
        if r.cache == nil {
            r.error = "响应里没找到车况字段：" + ArcApi.head(resp.body, 200)
        }
        return r
    }

    static func fetchCondition(_ s: Session) -> JSON? {
        var code = s.modelCode
        if code.isEmpty {
            s.loadVehicle()
            code = s.modelCode
        }
        guard !code.isEmpty, !s.vin.isEmpty, !s.mainToken.isEmpty else { return nil }
        let resp = ArcApi.vehicleCondition(s.vin, code, s.deviceId, s.mainToken)
        guard resp.bizOk else { return nil }
        return resp.json?.dict("data")
    }

    static func condInt(_ o: JSON?, _ k: String) -> Int {
        guard let o = o else { return -1 }
        let s = o.string(k).trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "null" { return -1 }
        return Int(Double(s).map { Int($0) } ?? -1)
    }

    static func expired(_ r: ArcApi.Resp?) -> Bool {
        guard let r = r else { return false }
        if r.http == 401 || r.http == 403 { return true }
        guard let j = r.json else { return false }
        let code = j.string("code")
        return code == "207" || code == "401"
    }

    // ------------------------------------------------------------- 解析

    static func parse(_ root: JSON?, _ model: String, _ plate: String,
                      _ cond: JSON?, _ heldLock: Int) -> JSON? {
        guard let root = root else { return nil }
        var d = root.dict("data") ?? root
        var st = d.dict("status") ?? JSON([:])

        var soc = num(d, "soc", "batterySoc", "socValue")
        var range = num(d, "limitedDriving", "autonomie", "endurance", "remainingRange")
        var odo = num(d, "kmTotal", "totalMileage", "odometer")
        var tin = num(d, "insideTemperature", "interiorTemperature", "inCarTemperature")
        let spd = num(d, "vehSpd", "speed")
        let cleft = num(d, "chargingleft", "chargeRemainTime")
        let cpow = num(d, "chrgDchaPwrDisp", "chrgDmPwr", "chargingPower")
        var tout = num(d, "outsideTemperature", "outTemperature", "outsideTemp", "envTemperature", "outTemp", "ambientTemperature")

        var lat: Double? = nil
        var lon: Double? = nil
        if let gps = d.dict("gps") {
            lat = num(gps, "latitude", "lat")
            lon = num(gps, "longitude", "lon", "lng")
            if let la = lat, abs(la) > 90 { lat = la / 1_000_000 }
            if let lo = lon, abs(lo) > 180 { lon = lo / 1_000_000 }
            if lat == 0 && lon == 0 { lat = nil; lon = nil }
        }

        if soc == nil && range == nil && odo == nil && tin == nil {
            soc = JsonProbe.findNumber(root.obj, "soc")
            range = JsonProbe.findNumber(root.obj, "limitedDriving", "autonomie")
            odo = JsonProbe.findNumber(root.obj, "kmTotal")
            tin = JsonProbe.findNumber(root.obj, "insideTemperature")
        }
        if tout == nil {
            tout = JsonProbe.findNumber(root.obj, "outsideTemperature", "outTemperature", "outsideTemp")
        }
        if soc == nil && range == nil && odo == nil && tin == nil { return nil }

        if let s0 = soc, s0 > 0, s0 <= 1 { soc = s0 * 100 }

        let tLf = tyre(st.dict("S105"), "LF")
        let tRf = tyre(st.dict("S105"), "RF")
        let tLb = tyre(st.dict("S105"), "LB")
        let tRb = tyre(st.dict("S105"), "RB")

        let lockStateV = lockState(st, heldLock)
        let locked = lockStateV == 1
        let sentry = sentryState(st)
        let charging = (cleft ?? 0) > 0 || (cpow ?? 0) > 0
        let carLock = condInt(cond, "carLock")
        let ac = condInt(cond, "ariConditioner")
        let win = condInt(cond, "window")

        let title = !plate.isEmpty ? plate : (!model.isEmpty ? model : "我的极狐")

        var o: [String: Any] = [:]
        o["title"] = title
        o["model"] = model
        o["soc"] = soc.map { "\(Int(($0).rounded()))%" } ?? "--%"
        o["range"] = range.map { "\(Int(($0).rounded())) km" } ?? "--km"
        o["odo"] = odo.map { "\(Int(($0).rounded())) km" } ?? "--"
        o["temp"] = tin.map { String(format: "%.2f℃", $0) } ?? "--"
        o["out"] = tout.map { String(format: "%.2f℃", $0) } ?? "--"
        if let la = lat, let lo = lon {
            o["lat"] = la
            o["lon"] = lo
        }
        o["tyre"] = tyreText(tLf, tRf, tLb, tRb)
        o["warn"] = false
        o["locked"] = locked
        o["lockKnown"] = lockStateV >= 0
        o["carLock"] = carLock
        let lockSrc = heldLock >= 0 ? "回执" : (st.has("S4") ? "S4" : (st.has("S3") ? "S3" : "四门"))
        o["lockSrc"] = lockSrc
        o["lockRaw"] = lockRaw(st)
        o["ac"] = ac
        o["acKnown"] = ac >= 0
        o["win"] = win
        o["winKnown"] = win >= 0
        o["sentry"] = sentry == 1
        o["sentryKnown"] = sentry >= 0
        o["charging"] = charging
        o["speed"] = spd.map { Int($0.rounded()) }

        let now = Date()
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = .current
        o["ts"] = f.string(from: now)
        let dataTs = Fetcher.hhmm(st.string("statusDataSendTime"))
        if !dataTs.isEmpty { o["dataTs"] = dataTs }

        var status = lockStateV > 0 ? "已锁车" : (lockStateV == 0 ? "未锁车" : "门锁未知")
        if charging { status += " · 充电中" }
        if sentry == 1 { status += " · 哨兵开启" }
        var sdt = st.string("statusDataSendTime")
        if !sdt.isEmpty {
            if sdt.count > 16 { sdt = String(sdt.suffix(11)) }
            status += " · 数据 " + sdt
        } else {
            status += " · 更新于 " + (o["ts"] as? String ?? "")
        }
        o["status"] = status

        let cache = JSON(o)
        return cache
    }

    static func lockState(_ st: JSON, _ held: Int) -> Int {
        if held >= 0 { return held }
        let s4 = st.string("S4").trimmingCharacters(in: .whitespaces)
        if s4 == "0" { return 1 }
        if s4 == "1" { return 0 }
        let s3 = st.string("S3").trimmingCharacters(in: .whitespaces)
        if !s3.isEmpty { return s3 == "0" ? 1 : 0 }
        var any = false
        var allClosed = true
        for k in ["S49", "S50", "S51", "S52"] {
            let v = st.string(k).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty {
                any = true
                if v != "4" { allClosed = false }
            }
        }
        return (any && allClosed) ? 1 : -1
    }

    static func hhmm(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " ")
        if let sp = t.firstIndex(of: " "), t.distance(from: sp, to: t.endIndex) >= 6 {
            t = String(t[t.index(after: sp)...])
        }
        return t.count >= 5 ? String(t.prefix(5)) : ""
    }

    static func lockRaw(_ st: JSON) -> String {
        var out = ""
        for k in ["S3", "S4", "S49", "S50", "S51", "S52"] {
            var v = st.string(k)
            if v.isEmpty { v = "-" }
            out += String(k.dropFirst()) + "=" + v + " "
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func sentryState(_ st: JSON) -> Int {
        let has116 = st.has("S116") && !st.string("S116").isEmpty
        let has112 = st.dict("S112") != nil
        if !has116 && !has112 { return -1 }
        if st.string("S116") == "3" { return 1 }
        if let s112 = st.dict("S112"), let sms = s112.dict("sms") {
            return sms.string("ot") == "1" ? 1 : 0
        }
        return 0
    }

    static func tyre(_ o: JSON?, _ k: String) -> Double? {
        guard let o = o else { return nil }
        var v = o.opt(k) ?? o.opt(k.lowercased())
        if let val = v?.value {
            if let sub = val as? [String: Any] {
                let j = JSON(sub)
                let inner = j.opt("TPV") ?? j.opt("tpv") ?? j.opt("value")
                v = inner
            }
        }
        guard let raw = v?.value else { return nil }
        var d: Double
        if let n = raw as? NSNumber {
            d = n.doubleValue
        } else {
            guard let p = JsonProbe.parseNumber(String(describing: raw)) else { return nil }
            d = p
        }
        if d <= 0 { return nil }
        return d > 50 ? d / 100 : d
    }

    static func num(_ o: JSON, _ keys: String...) -> Double? {
        for k in keys {
            if let v = o.opt(k)?.value, !(v is NSNull) {
                if let n = v as? NSNumber { return n.doubleValue }
                if let p = JsonProbe.parseNumber(String(describing: v)) { return p }
            }
        }
        return nil
    }

    static func tyreText(_ a: Double?, _ b: Double?, _ c: Double?, _ d: Double?) -> String {
        if a == nil && b == nil && c == nil && d == nil { return "--/--/--/--" }
        return p1(a) + "/" + p1(b) + "/" + p1(c) + "/" + p1(d)
    }

    static func p1(_ v: Double?) -> String {
        v.map { String(format: "%.2f", $0) } ?? "--"
    }
}

/// 小组件刷新桥：主 App / 扩展里拉完数据后调小组件重载。
enum WidgetBridge {
    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
