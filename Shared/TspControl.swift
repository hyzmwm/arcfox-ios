import Foundation

/// 远程控车（空调 / 门锁 / 车窗 / 寻车），对应 TspControl.java。
enum TspControl {
    static let cmdDoor = "4"
    static let cmdFind = "5"
    static let cmdSet = "2"
    static let cmdWindow = "6"
    static let defTemp = 24
    static let findMode = "3"
    static let groupAc = "10"
    static let kHold = "ac_hold"
    static let kLock = "lock_hold"
    static let kSeq = "tsp_seq"
    static let kTemp = "ac_temp"
    static let kWin = "win_hold"
    static let lockHoldMs: Int64 = 90_000
    static let winHoldMs: Int64 = 1_800_000
    static let pollGap: UInt32 = 2
    static let pollTimes = 5
    static let pOperate = "tdata-sync/public/tsp/remoteOperate"
    static let pResult = "tdata-sync/public/tsp/getRemoteOperateResult"

    struct Res {
        var accepted = false
        var done = false
        var needApp = false
        var on = false
        var re: JSON?
        var door = -1
        var win = -1
        var cr = ""
        var msg = ""
        var detail = ""
        /// 本次开关窗指令的方向（setWindow 里写入，toggleWindow 读取）
        var winSet = false
    }

    // ------------------------------------------------------------- 状态读取

    static func acState() -> Int {
        guard let cache = readCache() else { return -1 }
        return cache.int("ac", -1)
    }

    static func acOn() -> Bool { acState() == 1 }

    static func temp() -> Int {
        let i = Store.getInt(Store.kAcTemp, defTemp)
        return (i < 16 || i > 32) ? defTemp : i
    }

    static func lockState() -> Int {
        guard let cache = readCache() else { return -1 }
        return cache.bool("locked", false) ? 1 : 0
    }

    static func windowState() -> Int {
        let held = heldWindow()
        if held >= 0 { return held }
        guard let cache = readCache() else { return -1 }
        return cache.int("win", -1)
    }

    static func heldLock() -> Int {
        let s = Store.get(kLock)
        if s.isEmpty { return -1 }
        let parts = s.split(separator: ":")
        guard let i = Int(parts[0]) else { return -1 }
        let ts = parts.count > 1 ? Int64(parts[1]) ?? 0 : 0
        if Int64(Date().timeIntervalSince1970 * 1000) - ts > lockHoldMs { return -1 }
        return i == 1 ? 1 : 0
    }

    static func heldWindow() -> Int {
        let s = Store.get(kWin)
        if s.isEmpty { return -1 }
        let parts = s.split(separator: ":")
        guard let i = Int(parts[0]) else { return -1 }
        let ts = parts.count > 1 ? Int64(parts[1]) ?? 0 : 0
        if Int64(Date().timeIntervalSince1970 * 1000) - ts > winHoldMs { return -1 }
        return i == 1 ? 1 : 0
    }

    /// 把 hold 记账压回车况缓存（车端旧值回跳保护）
    static func reconcile(_ cache: JSON) {
        applyHold(cache, key: kHold, holdMs: 180_000, field: "ac")
        applyHold(cache, key: kWin, holdMs: winHoldMs, field: "win")
    }

    private static func applyHold(_ cache: JSON, key: String, holdMs: Int64, field: String) {
        let s = Store.get(key)
        let parts = s.split(separator: ":")
        guard parts.count > 1, let i = Int(parts[0]) else { return }
        let ts = Int64(parts[1]) ?? 0
        if Int64(Date().timeIntervalSince1970 * 1000) - ts > holdMs {
            Store.remove(key)
            return
        }
        if cache.int(field, -1) == i { return }
        cache.obj[field] = i
        cache.obj[field + "Known"] = true
    }

    // ------------------------------------------------------------- 动作

    static func toggle(_ polls: Int = pollTimes) -> Res {
        setAc(on: acState() != 1, polls: polls)
    }

    static func setAc(on: Bool, polls: Int = pollTimes) -> Res {
        let s = Session.shared
        var res = Res()
        let vin = s.vin
        if vin.isEmpty {
            res.msg = "空调：还没拿到 VIN，先刷新一次车况"
            return res
        }
        var token = s.mainToken
        if token.isEmpty { token = s.tspToken }
        if token.isEmpty {
            res.needApp = true
            res.msg = "空调：还没登录极狐账号"
            res.detail = "mainToken / tspToken 都是空的"
            return res
        }
        let t = temp()
        let remote = remoteToken()
        let seq = nextSeq()
        let payload = payloadAc(vin, remote, seq, on, t)
        let resp = ArcApi.accountPostRaw(pOperate, s.deviceId, payload, token)
        res.detail = "POST tdata-sync/public/tsp/remoteOperate\n→ \(payload)\n← HTTP \(resp.http) \(ArcApi.head(resp.body, 400))"
        if !resp.ok || !resp.bizOk {
            res.needApp = authBroken(resp)
            res.msg = "空调指令失败：" + resp.describe
            saveLog("空调 \(on ? "开启" : "关闭") 下发失败", res.detail)
            return res
        }
        res.accepted = true
        var lastCr = ""
        for _ in 0..<polls {
            Thread.sleep(forTimeInterval: TimeInterval(pollGap))
            let r = ArcApi.accountGet(pResult, s.deviceId, token, ["remoteToken": remote])
            if let j = r.json, let content = resultContent(j) {
                let body = content.dict("body")
                let cr = body?.string("CR").trimmingCharacters(in: .whitespaces) ?? ""
                if cr != "1" && !cr.isEmpty {
                    if cr == "257" {
                        res.msg = "空调指令被服务端按重复丢弃（SEQ 撞了），再点一次"
                        saveLog("空调指令被丢弃", res.detail + "\n← 回执 CR=257 " + ArcApi.head(r.body, 200))
                        return res
                    }
                    if cr == "256" {
                        let s80 = body?.dict("RE")?.string("S80").trimmingCharacters(in: .whitespaces) ?? ""
                        res.done = true
                        res.on = s80.isEmpty ? on : (s80 == "1")
                        applyCache(res.on ? 1 : 0)
                        res.msg = res.on ? "空调已开启 · \(t)℃" : "空调已关闭"
                        res.detail += "\n← 回执 CR=256 " + ArcApi.head(r.body, 300)
                        saveLog(res.msg, res.detail)
                        return res
                    }
                    res.msg = "空调指令回执异常（CR=\(cr)）"
                    saveLog("空调回执异常", res.detail + "\n← " + ArcApi.head(r.body, 300))
                    return res
                }
                lastCr = cr
            }
        }
        res.msg = "空调指令已下发，车端唤醒中（约 15 秒后自动更新）"
        res.detail += "\n← 轮询 \(polls) 次无终态，最后 CR=\(lastCr.isEmpty ? "空" : lastCr)"
        saveLog(res.msg, res.detail)
        return res
    }

    static func setDoor(_ lock: Bool, polls: Int = pollTimes) -> Res {
        let name = lock ? "锁车" : "解锁"
        let s = Session.shared
        var res = Res()
        let vin = s.vin
        if vin.isEmpty {
            res.msg = "\(name)：还没拿到 VIN，先刷新一次车况"
            return res
        }
        var token = s.mainToken
        if token.isEmpty { token = s.tspToken }
        if token.isEmpty {
            res.needApp = true
            res.msg = "\(name)：还没登录极狐账号"
            res.detail = "mainToken / tspToken 都是空的"
            return res
        }
        let remote = remoteToken()
        let seq = nextSeq()
        let payload = payloadDoor(vin, remote, seq, lock)
        let resp = ArcApi.accountPostRaw(pOperate, s.deviceId, payload, token)
        res.detail = "POST tdata-sync/public/tsp/remoteOperate\n→ \(payload)\n← HTTP \(resp.http) \(ArcApi.head(resp.body, 400))"
        if !resp.ok || !resp.bizOk {
            res.needApp = authBroken(resp)
            res.msg = "\(name)指令失败：" + resp.describe
            saveLog("\(name) 下发失败", res.detail)
            return res
        }
        res.accepted = true
        // 锁状态按指令方向立即落盘，车端回执 S4 滞后不覆盖
        applyLock(lock ? 1 : 0)
        var lastCr = ""
        for _ in 0..<polls {
            Thread.sleep(forTimeInterval: TimeInterval(pollGap))
            let r = ArcApi.accountGet(pResult, s.deviceId, token, ["remoteToken": remote])
            if let j = r.json, let content = resultContent(j) {
                let body = content.dict("body")
                let cr = body?.string("CR").trimmingCharacters(in: .whitespaces) ?? ""
                if cr != "1" && !cr.isEmpty {
                    if cr == "257" {
                        res.msg = "\(name)指令被服务端按重复丢弃（SEQ 撞了），再点一次"
                        saveLog("\(name) 被丢弃", res.detail + "\n← 回执 CR=257 " + ArcApi.head(r.body, 200))
                        return res
                    }
                    if cr == "256" || cr == "285" {
                        let s4 = body?.dict("RE")?.string("S4").trimmingCharacters(in: .whitespaces) ?? ""
                        res.done = true
                        res.door = lock ? 1 : 0
                        res.msg = res.door == 1 ? "车已锁上" : "车已解锁"
                        if s4.isEmpty { res.msg += "（车端未回报状态，按指令方向确认）" }
                        res.detail += "\n← 回执 CR=\(cr) " + ArcApi.head(r.body, 300)
                        saveLog(res.msg, res.detail)
                        return res
                    }
                    res.msg = "\(name)指令回执异常（CR=\(cr)）"
                    saveLog("\(name)回执异常", res.detail + "\n← " + ArcApi.head(r.body, 300))
                    return res
                }
                lastCr = cr
            }
        }
        res.msg = "\(name)指令已下发，车端唤醒中（约 15 秒后自动更新）"
        res.detail += "\n← 轮询 \(polls) 次无终态，最后 CR=\(lastCr.isEmpty ? "空" : lastCr)"
        saveLog(res.msg, res.detail)
        return res
    }

    static func toggleWindow(_ polls: Int = pollTimes) -> Res {
        var res = setWindow(open: windowState() != 1, polls: polls)
        if res.accepted {
            applyWindow(res.winSet ? 1 : 0)
        }
        if !res.done { return res }
        var report = -1
        if let re = res.re {
            for k in ["S75", "S76", "S77"] {
                let v = re.string(k).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty {
                    if v == "1" { report = 1; break }
                    report = 0
                }
            }
        }
        res.win = res.winSet ? 1 : 0
        applyWindow(res.win)
        res.msg = res.win == 1 ? "车窗已打开" : "车窗已关闭"
        if report < 0 { res.msg += "（车端未回报车窗状态，按指令方向确认）" }
        saveLog(res.msg, res.detail)
        return res
    }

    static func setWindow(open: Bool, polls: Int = pollTimes) -> Res {
        var res = toRes(exec("车窗", cmdWindow, open ? "1" : cmdSet, p1: "1", polls: polls))
        res.winSet = open
        if res.done {
            res.msg = open ? "车窗已打开" : "车窗已关闭"
        }
        return res
    }

    static func find(_ polls: Int = pollTimes) -> Res {
        var res = toRes(exec("寻车", cmdFind, "1", p1: findMode, polls: polls))
        if res.done {
            res.msg = "寻车已触发（鸣笛 + 闪灯）"
            saveLog(res.msg, res.detail + "\n← 寻车是瞬时动作，回执不带 RE")
        }
        return res
    }

    // ------------------------------------------------------------- 内部执行

    /// 把内部执行结果转成对外统一的 Res（只搬共有字段）。
    private static func toRes(_ e: ExecRes) -> Res {
        var r = Res()
        r.accepted = e.accepted
        r.done = e.done
        r.needApp = e.needApp
        r.re = e.re
        r.cr = e.cr
        r.msg = e.msg
        r.detail = e.detail
        return r
    }

    private struct ExecRes {
        var accepted = false
        var done = false
        var needApp = false
        var re: JSON?
        var cr = ""
        var msg = ""
        var detail = ""
    }

    private static func exec(_ name: String, _ cmd: String, _ c: String, p1: String, polls: Int) -> ExecRes {        let s = Session.shared
        var res = ExecRes()
        let vin = s.vin
        if vin.isEmpty {
            res.msg = "\(name)：还没拿到 VIN，先刷新一次车况"
            return res
        }
        var token = s.mainToken
        if token.isEmpty { token = s.tspToken }
        if token.isEmpty {
            res.needApp = true
            res.msg = "\(name)：还没登录极狐账号"
            res.detail = "mainToken / tspToken 都是空的"
            return res
        }
        let remote = remoteToken()
        let seq = nextSeq()
        let payload = payloadOf(vin, remote, seq, cmd, c, ["P1": p1])
        let resp = ArcApi.accountPostRaw(pOperate, s.deviceId, payload, token)
        res.detail = "POST tdata-sync/public/tsp/remoteOperate\n→ \(payload)\n← HTTP \(resp.http) \(ArcApi.head(resp.body, 400))"
        if !resp.ok || !resp.bizOk {
            res.needApp = authBroken(resp)
            res.msg = "\(name)指令失败：" + resp.describe
            saveLog("\(name) 下发失败", res.detail)
            return res
        }
        res.accepted = true
        var lastCr = ""
        for _ in 0..<polls {
            Thread.sleep(forTimeInterval: TimeInterval(pollGap))
            let r = ArcApi.accountGet(pResult, s.deviceId, token, ["remoteToken": remote])
            if let j = r.json, let content = resultContent(j) {
                let body = content.dict("body")
                let cr = body?.string("CR").trimmingCharacters(in: .whitespaces) ?? ""
                if cr == "1" || cr.isEmpty {
                    lastCr = cr
                } else {
                    res.cr = cr
                    if cr == "257" {
                        res.msg = "\(name)指令被服务端按重复丢弃（SEQ 撞了），再点一次"
                        saveLog("\(name)被丢弃", res.detail + "\n← 回执 CR=257 " + ArcApi.head(r.body, 200))
                        return res
                    }
                    if cr == "256" || cr == "285" {
                        res.done = true
                        res.re = body?.dict("RE")
                        res.detail += "\n← 回执 CR=\(cr) " + ArcApi.head(r.body, 300)
                        return res
                    }
                    res.msg = "\(name)指令回执异常（CR=\(cr)）"
                    saveLog("\(name)回执异常", res.detail + "\n← " + ArcApi.head(r.body, 300))
                    return res
                }
            }
        }
        res.msg = "\(name)指令已下发，车端唤醒中（约 15 秒后自动更新）"
        res.detail += "\n← 轮询 \(polls) 次无终态，最后 CR=\(lastCr.isEmpty ? "空" : lastCr)"
        saveLog(res.msg, res.detail)
        return res
    }

    // ------------------------------------------------------------- payload

    static func payloadDoor(_ vin: String, _ remote: String, _ seq: String, _ lock: Bool) -> String {
        let header: [String: Any] = [
            "CMD": cmdDoor, "DOWN": "1", "GROUP": groupAc, "SEQ": seq,
            "ST": stamp(), "TOKEN": remote, "VER": "1",
        ]
        let body: [String: Any] = ["C": lock ? cmdSet : "1", "P1": "1"]
        let outer: [String: Any] = [
            "cmd": JSON(["header": header, "body": body]).rawUnsorted,
            "type": "2101",
            "vin": vin,
        ]
        return JSON(outer).rawUnsorted
    }

    static func payloadAc(_ vin: String, _ remote: String, _ seq: String, _ on: Bool, _ t: Int) -> String {
        let header: [String: Any] = [
            "CMD": cmdSet, "DOWN": "1", "GROUP": groupAc, "SEQ": seq,
            "ST": stamp(), "TOKEN": remote, "VER": "1",
        ]
        var body: [String: Any] = ["C": on ? "1" : cmdSet]
        if on { body["P1"] = String(t) }
        let outer: [String: Any] = [
            "cmd": JSON(["header": header, "body": body]).rawUnsorted,
            "type": "2101",
            "vin": vin,
        ]
        return JSON(outer).rawUnsorted
    }

    static func payloadOf(_ vin: String, _ remote: String, _ seq: String, _ cmd: String, _ c: String, _ extra: [String: String]) -> String {
        let header: [String: Any] = [
            "CMD": cmd, "DOWN": "1", "GROUP": groupAc, "SEQ": seq,
            "ST": stamp(), "TOKEN": remote, "VER": "1",
        ]
        var body: [String: Any] = ["C": c]
        for (k, v) in extra { body[k] = v }
        let outer: [String: Any] = [
            "cmd": JSON(["header": header, "body": body]).rawUnsorted,
            "type": "2101",
            "vin": vin,
        ]
        return JSON(outer).rawUnsorted
    }

    static func remoteToken() -> String {
        var s = "A" + String(Int64(Date().timeIntervalSince1970 * 1000))
        var num = String(abs(Int64.random(in: 0..<Int64.max)) % 100_000_000_000)
        while num.count < 11 { num = "0" + num }
        s += String(num.prefix(11))
        return s
    }

    static func nextSeq() -> String {
        var seq = Store.getLong(kSeq, 0)
        if seq <= 0 { seq = abs(Int64(Date().timeIntervalSince1970)) % 100_000 }
        seq += 1
        Store.setLong(kSeq, seq)
        return String(seq)
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    static func resultContent(_ j: JSON) -> JSON? {
        j.dict("data")?.dict("resultContent")
    }

    static func authBroken(_ r: ArcApi.Resp) -> Bool {
        if r.http == 401 || r.http == 403 { return true }
        let b = r.body.lowercased()
        return b.contains("token invalid") || b.contains("100011") || b.contains("100012")
            || b.contains("token失效") || b.contains("未登录")
    }

    static func applyCache(_ i: Int) {
        Store.set(kHold, "\(i):\(Int64(Date().timeIntervalSince1970 * 1000))")
        if let cache = readCache() {
            cache.obj["ac"] = i
            cache.obj["acKnown"] = true
            Store.set(Store.kCache, cache.rawUnsorted)
        }
    }

    static func applyLock(_ i: Int) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        Store.set(kLock, "\(i):\(ts)")
        if let cache = readCache() {
            cache.obj["locked"] = (i == 1)
            cache.obj["lockKnown"] = true
            cache.obj["lockTs"] = ts
            Store.set(Store.kCache, cache.rawUnsorted)
        }
    }

    static func applyWindow(_ i: Int) {
        Store.set(kWin, "\(i):\(Int64(Date().timeIntervalSince1970 * 1000))")
        if let cache = readCache() {
            cache.obj["win"] = i
            cache.obj["winKnown"] = true
            Store.set(Store.kCache, cache.rawUnsorted)
        }
    }

    static func readCache() -> JSON? {
        let s = Store.get(Store.kCache)
        if s.isEmpty { return nil }
        let j = JSON(s)
        return j.obj.isEmpty ? nil : j
    }

    static func saveLog(_ title: String, _ detail: String) {
        Store.set(Store.kCtrlLog, title + "\n" + detail)
    }
}

