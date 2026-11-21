import SwiftUI
import BackgroundTasks

/// 后台自动刷新（对应 AutoRefresh.java + AlarmManager → BGAppRefreshTask）
enum BackgroundRefresh {
    static let taskId = "com.arcfoxplus.widget.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            scheduleNext()
            let r = Fetcher.fetch()
            WidgetBridge.reloadWidgets()
            task.setTaskCompleted(success: r.cache != nil)
        }
    }

    static func scheduleNext() {
        let req = BGAppRefreshTaskRequest(identifier: taskId)
        let min = Store.getInt(Store.kAutoMin, 15)
        guard min > 0 else { return }
        req.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(min * 60))
        try? BGTaskScheduler.shared.submit(req)
    }
}

/// 状态对象：持有最近一次车况缓存 + 刷新逻辑，供主界面与各子页共用。
final class AppState: ObservableObject {
    @Published var cache: JSON?
    @Published var lastError = ""
    @Published var needLogin = false
    @Published var loading = false
    @Published var toast: String?

    init() {
        cache = TspControl.readCache()
    }

    var autoMin: Int {
        get { Store.getInt(Store.kAutoMin, 15) }
        set {
            Store.setInt(Store.kAutoMin, newValue)
            if #available(iOS 16.0, *) { BackgroundRefresh.scheduleNext() }
        }
    }

    func refresh(background: Bool = false) {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = Fetcher.fetch()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                if let c = r.cache {
                    TspControl.reconcile(c)
                    Store.set(Store.kCache, c.rawUnsorted)
                    Store.setLong(Store.kCacheTs, Int64(Date().timeIntervalSince1970 * 1000))
                    self.cache = c
                    self.lastError = ""
                    self.needLogin = false
                } else {
                    self.lastError = r.error ?? "取不到车况数据"
                    self.needLogin = r.needLogin
                }
                WidgetBridge.reloadWidgets()
            }
        }
    }

    var session: Session { Session.shared }
}
