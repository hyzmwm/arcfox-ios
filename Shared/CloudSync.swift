import Foundation
import CryptoKit

/// 云同步中转：证书没有 App Group 权限（如全能签普通证书）时的兜底通道。
/// 主 App 把全量键值（车况缓存 + 登录态 + 设置）压缩加密后发布到 ntfy 私有主题，
/// 小组件扩展用「同步码」（即主题名）拉回并导入本地存储，之后控车/刷新照常工作。
/// 载荷：JSON → zlib 压缩 → AES-GCM 加密（密钥由同步码派生）→ base64。
enum CloudSync {
    private static let base = "https://ntfy.sh"
    private static let marker = "arcfox-widget-sync"

    static var enabled: Bool {
        get { Store.getInt(Store.kCloudOn, 0) == 1 }
        set { Store.setInt(Store.kCloudOn, newValue ? 1 : 0) }
    }

    static var topic: String { Store.get(Store.kCloudTopic) }

    /// 生成新的同步码（随机私有主题名，不可猜测）。
    @discardableResult
    static func newTopic() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var s = ""
        for _ in 0..<14 { s.append(chars.randomElement()!) }
        Store.set(Store.kCloudTopic, s)
        return s
    }

    static var lastUploadText: String {
        let ts = Store.getLong(Store.kCloudTs, 0)
        guard ts > 0 else { return "还没上传过" }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return "上次上传 " + df.string(from: Date(timeIntervalSince1970: Double(ts) / 1000))
    }

    private static func aesKey(_ code: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data((marker + "|" + code).utf8)))
    }

    private static func seal(_ dict: [String: Any], code: String) -> String? {
        guard JSONSerialization.isValidJSONObject(dict),
              let json = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        let z = try (json as NSData).compressed(using: .zlib) as Data
        guard let box = try? AES.GCM.seal(z, using: aesKey(code)),
              let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    private static func open(_ b64: String, code: String) -> [String: Any]? {
        guard let raw = Data(base64Encoded: b64),
              let box = try? AES.GCM.SealedBox(combined: raw),
              let z = try? AES.GCM.open(box, using: aesKey(code)) else { return nil }
        let json = try (z as NSData).decompressed(using: .zlib) as Data
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    private static func http(_ req: URLRequest) -> (Data?, Int) {
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        var code = 0
        URLSession.shared.dataTask(with: req) { d, r, _ in
            out = d
            code = (r as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        sem.wait()
        return (out, code)
    }

    /// 主 App 上传（后台线程调用）。返回 nil = 成功，否则错误信息。
    @discardableResult
    static func upload() -> String? {
        guard enabled else { return nil }
        let code = topic
        guard !code.isEmpty else { return "没有同步码" }
        guard let payload = seal(Store.exportDict(), code: code) else { return "载荷编码失败" }
        guard payload.count < 3600 else { return "载荷过大(\(payload.count)B)" }
        var req = URLRequest(url: URL(string: "\(base)/\(code)")!)
        req.httpMethod = "POST"
        req.setValue(marker, forHTTPHeaderField: "Title")
        req.httpBody = Data(payload.utf8)
        req.timeoutInterval = 30
        let (_, st) = http(req)
        if (200..<300).contains(st) {
            Store.setLong(Store.kCloudTs, Int64(Date().timeIntervalSince1970 * 1000))
            return nil
        }
        return "上传失败 HTTP \(st)"
    }

    /// 小组件下载并导入本地。返回 nil = 成功，否则错误信息。
    @discardableResult
    static func download(code: String) -> String? {
        guard !code.isEmpty else { return "未配置同步码" }
        var req = URLRequest(url: URL(string: "\(base)/\(code)/json?poll=1&since=all")!)
        req.timeoutInterval = 30
        let (data, st) = http(req)
        guard (200..<300).contains(st), let data = data else { return "下载失败 HTTP \(st)" }
        // ntfy json 流：一行一个 JSON，取最后一条消息
        var last: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["event"] as? String == "message" else { continue }
            last = o["message"] as? String
        }
        guard let msg = last else { return "云端还没有数据，请先打开App刷新一次" }
        guard let dict = open(msg, code: code) else { return "解密失败（同步码不一致？）" }
        Store.importDict(dict)
        return nil
    }
}
