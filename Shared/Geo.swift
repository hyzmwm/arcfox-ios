import Foundation
import CoreLocation

/// 逆地理编码流水线（对应 Geo.java）：高德 → Nominatim → Photon → BigDataCloud → CLGeocoder → 内置城市表。
enum Geo {
    static let amapBuiltIn = "ed64d468299895e155cb5e09df454441"
    static var lastDebug = ""
    static var lastAmap = ""

    static func describe(_ lat: Double, _ lon: Double) -> String {
        if let hit = fromCache(lat, lon) { return hit }
        var text: String? = nil
        var source = ""
        var key = Store.get(Store.kAmapUser).trimmingCharacters(in: .whitespaces)
        if key.isEmpty { key = amapBuiltIn }
        if !key.isEmpty {
            text = viaAmap(key, lat, lon)
            if text != nil { source = "amap" }
        }
        if text == nil { text = viaNominatim(lat, lon); if text != nil { source = "osm" } }
        if text == nil { text = viaPhoton(lat, lon); if text != nil { source = "photon" } }
        if text == nil { text = viaBigDataCloud(lat, lon); if text != nil { source = "bdc" } }
        if text == nil { text = viaGeocoder(lat, lon); if text != nil { source = "geocoder" } }
        if text == nil { text = nearestCity(lat, lon); source = "city" }
        if text == nil {
            text = String(format: "%.3f, %.3f", lat, lon)
            source = "coord"
        }
        saveCache(lat, lon, text!, source)
        lastDebug = source + " | " + text!
        return text!
    }

    // ------------------------------------------------------------- 缓存

    private static func grid(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.4f,%.4f", lat, lon)
    }

    private static func fromCache(_ lat: Double, _ lon: Double) -> String? {
        let raw = Store.get(Store.kGeoCache)
        if raw.isEmpty { return nil }
        let p = raw.components(separatedBy: "|")
        guard p.count >= 5, p[0] == grid(lat, lon) else { return nil }
        guard let ts = Int64(p[1]), let ttl = Int64(p[2]) else { return nil }
        if Int64(Date().timeIntervalSince1970 * 1000) - ts > ttl { return nil }
        return p[4].isEmpty ? nil : p[4]
    }

    private static func saveCache(_ lat: Double, _ lon: Double, _ text: String, _ source: String) {
        let ttl: Int64
        switch source {
        case "amap": ttl = 86_400_000
        case "osm", "photon": ttl = 1_800_000
        default: ttl = 600_000
        }
        Store.set(Store.kGeoCache, "\(grid(lat, lon))|\(Int64(Date().timeIntervalSince1970 * 1000))|\(ttl)|\(source)|\(text)")
    }

    // ------------------------------------------------------------- 高德

    private static func viaAmap(_ key: String, _ lat: Double, _ lon: Double) -> String? {
        let url = "https://restapi.amap.com/v3/geocode/regeo?key=\(ArcApi.enc(key))"
            + "&location=" + String(format: "%.6f,%.6f", lon, lat)
            + "&extensions=all&radius=300&batch=false"
        let body = httpGet(url, ua: "ArcfoxWidget/3.0 (iOS widget; personal use)", timeout: 4.5)
        if body.isEmpty { return nil }
        let j = JSON(body)
        if j.string("status") != "1" { return nil }
        guard let regeocode = j.dict("regeocode") else { return nil }
        let formatted = regeocode.string("formatted_address")
        guard let comp = regeocode.dict("addressComponent") else { return nil }
        let area = firstNonEmpty(comp.string("district"), comp.string("city"), comp.string("province"))
        let tail = stripAdmin(formatted)
        var poi = ""
        if let pois = regeocode.array("pois"), let p0 = pois.first {
            poi = (p0["name"] as? String) ?? ""
        }
        let sn = comp.dict("streetNumber")
        let detail = sn == nil ? "" : joinNonEmpty(sn!.string("street"), sn!.string("number"))
        lastAmap = "区=\(area) | 街道=\(tail) | POI=\(poi) | 门牌=\(detail) | 原始=\(formatted)"
        var place: String
        if !tail.isEmpty && tail.count <= 14 {
            place = tail
        } else {
            place = firstNonEmpty(
                comp.dict("neighborhood")?.string("name") ?? "",
                comp.dict("building")?.string("name") ?? "",
                poi, detail, tail)
        }
        let out = shortAddress(area, place)
        if out.count >= 3 { return out }
        let addr = compact(tidy(formatted))
        return addr.count >= 3 ? addr : nil
    }

    // ------------------------------------------------------------- 免 Key 兜底

    private static func viaNominatim(_ lat: Double, _ lon: Double) -> String? {
        let url = "https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=18&addressdetails=1"
            + "&accept-language=zh-CN"
            + "&lat=" + String(format: "%.6f", lat) + "&lon=" + String(format: "%.6f", lon)
        let body = httpGet(url, ua: "ArcfoxWidget/3.0 (iOS widget; personal use)", timeout: 4)
        if body.isEmpty { return nil }
        guard let a = JSON(body).dict("address") else { return nil }
        let city = firstNonEmpty(a.string("city"), a.string("municipality"), a.string("state"), a.string("province"))
        let district = firstNonEmpty(a.string("city_district"), a.string("district"), a.string("suburb"),
                                     a.string("town"), a.string("county"), a.string("village"))
        let road = firstNonEmpty(a.string("road"), a.string("pedestrian"), a.string("footway"),
                                 a.string("residential"), a.string("neighbourhood"),
                                 a.string("quarter"), a.string("hamlet"), a.string("industrial"))
        let num = a.string("house_number")
        var sb = appendAll([city, district, road])
        if !num.isEmpty && !road.isEmpty { sb += num }
        let out = compact(tidy(sb))
        if out.count < 3 || out == "中国" { return nil }
        return out
    }

    private static func viaPhoton(_ lat: Double, _ lon: Double) -> String? {
        let url = "https://photon.komoot.io/reverse?lang=zh&limit=1"
            + "&lat=" + String(format: "%.6f", lat) + "&lon=" + String(format: "%.6f", lon)
        let body = httpGet(url, ua: "ArcfoxWidget/3.0 (iOS widget; personal use)", timeout: 4)
        if body.isEmpty { return nil }
        guard let features = JSON(body).array("features"), let f0 = features.first,
              let props = f0["properties"] as? [String: Any] else { return nil }
        let p = JSON(props)
        var sb = appendAll([p.string("state"), p.string("city"), p.string("district")])
        let street = p.string("street")
        let num = p.string("housenumber")
        sb = appendAll([sb, street])
        if !num.isEmpty && !street.isEmpty { sb += num }
        let out = compact(tidy(sb))
        if out.count >= 3 && out != "中国" { return out }
        let name = compact(tidy(p.string("name")))
        return name.count >= 3 ? name : nil
    }

    private static func viaBigDataCloud(_ lat: Double, _ lon: Double) -> String? {
        let url = "https://api.bigdatacloud.net/data/reverse-geocode-client?localityLanguage=zh"
            + "&latitude=" + String(format: "%.6f", lat) + "&longitude=" + String(format: "%.6f", lon)
        let body = httpGet(url, ua: "ArcfoxWidget/3.0 (iOS widget; personal use)", timeout: 3.5)
        if body.isEmpty { return nil }
        let j = JSON(body)
        let sb = appendAll([j.string("principalSubdivision"), j.string("city"), j.string("locality")])
        let out = compact(tidy(sb))
        if out.count < 3 || out == "中国" { return nil }
        return out
    }

    private static func viaGeocoder(_ lat: Double, _ lon: Double) -> String? {
        let geo = CLGeocoder()
        var result: String?
        let sem = DispatchSemaphore(value: 0)
        geo.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon),
                                   preferredLocale: Locale(identifier: "zh_CN")) { marks, _ in
            if let a = marks?.first {
                var parts: [String] = []
                if let v = a.administrativeArea, !v.isEmpty { parts.append(v) }
                if let v = a.locality, !v.isEmpty { parts.append(v) }
                if let v = a.subLocality, !v.isEmpty { parts.append(v) }
                if let v = a.thoroughfare, !v.isEmpty { parts.append(v) }
                let out = compact(tidy(parts.joined()))
                if out.count >= 4 && out != "中国" { result = out }
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + .seconds(4))
        return result
    }

    // ------------------------------------------------------------- 内置城市表

    static func nearestCity(_ lat: Double, _ lon: Double) -> String? {
        var best: String? = nil
        var bestDist = 100.0
        for row in CityTable.entries {
            let dy = (lat - row.lat) * 111.0
            let dx = (lon - row.lon) * 111.0 * cos(row.lat * .pi / 180)
            let d = (dx * dx + dy * dy).squareRoot()
            if d < bestDist {
                best = row.name
                bestDist = d
            }
        }
        guard let city = best else { return nil }
        return bestDist > 45.0 ? city + " 附近" : city
    }

    // ------------------------------------------------------------- 文本工具

    private static func firstNonEmpty(_ vals: String...) -> String {
        for v in vals {
            let t = v.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return ""
    }

    private static func joinNonEmpty(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + b
    }

    private static func shortAddress(_ area: String, _ place: String) -> String {
        let a = tidy(area)
        let p = tidy(place)
        if p.isEmpty { return compact(a) }
        if a.isEmpty || a == p || p.contains(a) || p.count > 10 {
            return trimTail(p)
        }
        return trimTail(a + "·" + p)
    }

    private static func stripAdmin(_ formatted: String) -> String {
        var v = tidy(formatted)
        v = v.replacingOccurrences(of: "^[^省]{1,8}省", with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: "^[^市]{1,8}市", with: "", options: .regularExpression)
        v = v.replacingOccurrences(of: "^[^区县]{1,8}[区县]", with: "", options: .regularExpression)
        return v.trimmingCharacters(in: .whitespaces)
    }

    private static func trimTail(_ s: String) -> String {
        s.count <= 14 ? s : String(s.suffix(14))
    }

    static func compact(_ s: String) -> String {
        var v = s.replacingOccurrences(of: " ", with: "")
        if let city = v.firstIndex(of: "市"), v.distance(from: v.startIndex, to: city) < v.count - 3 {
            let rest = String(v[v.index(after: city)...])
            if rest.count >= 4 { v = rest }
        }
        return v.count <= 14 ? v : String(v.suffix(14))
    }

    static func tidy(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("中国") { v = String(v.dropFirst(2)) }
        v = v.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{3000}", with: "")
        if let i = v.firstIndex(of: "省") {
            let head = String(v[...i])
            let rest = String(v[v.index(after: i)...])
            if rest.hasPrefix(head) { v = head + String(rest.dropFirst(head.count)) }
        } else if let i = v.firstIndex(of: "市") {
            let head = String(v[...i])
            let rest = String(v[v.index(after: i)...])
            if rest.hasPrefix(head) { v = head + String(rest.dropFirst(head.count)) }
        }
        while let r = v.range(of: "([市省]{2,4}市|市{2,4}|省{2,4})\\1", options: .regularExpression) {
            let m = v[r]
            let half = String(m.prefix(m.count / 2))
            v = v.replacingOccurrences(of: m, with: half)
            break
        }
        return v
    }

    private static func appendAll(_ vals: [String]) -> String {
        var out = ""
        for raw in vals {
            let v = raw.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty && !out.contains(v) {
                out += v
            }
        }
        return out
    }

    static func httpGet(_ urlStr: String, ua: String, timeout: Double) -> String {
        guard let url = URL(string: urlStr) else { return "" }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: req) { data, _, _ in
            body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + .seconds(Int(timeout) + 1))
        return body
    }

    /// 地图链接：iOS 上给高德网页版（免 scheme 白名单，所有浏览器/浏览器内 WebView 可开）。
    static func mapURL(_ lat: Double, _ lon: Double, _ name: String) -> URL? {
        var namePart = ""
        if !name.isEmpty, let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            namePart = "&name=\(enc)"
        }
        return URL(string: "https://uri.amap.com/marker?position=\(lon),\(lat)\(namePart)&callnative=1")
    }
}
