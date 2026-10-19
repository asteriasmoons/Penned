import Foundation

@MainActor
enum PennedSyncNotifications {
    static var synchronize: (() async -> Void)?
}

#if canImport(UIKit)
import UIKit

@MainActor
final class PennedApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            if let synchronize = PennedSyncNotifications.synchronize {
                await synchronize(); completionHandler(.newData)
            } else { completionHandler(.noData) }
        }
    }
}
#elseif canImport(AppKit)
import AppKit

@MainActor
final class PennedApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { @MainActor in await PennedSyncNotifications.synchronize?() }
    }
}
#endif
