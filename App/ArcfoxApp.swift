import SwiftUI
import UIKit

@main
struct ArcfoxApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(Theme.scheme)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundRefresh.register()
        return true
    }

    func application(_ application: UIApplication,
                     performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        DispatchQueue.global().async {
            let r = Fetcher.fetch()
            WidgetBridge.reloadWidgets()
            completionHandler(r.cache != nil ? .newData : .failed)
        }
    }
}

/// 昼夜配色（对应 WidgetTheme / KEY_WIDGET_THEME：light / dark / auto）
enum Theme {
    static var raw: String { Store.get(Store.kWidgetTheme, "auto") }

    static var scheme: ColorScheme? {
        switch raw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
