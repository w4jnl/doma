// The phone's two ways to sync with the app off screen: a silent push from the server, and the
// system's background refresh about every 15 minutes. Push is a hint; a device that misses it
// catches up on the next trigger. No visible notifications in v1, and only the badge permission
// is asked, for the open count on the icon.
import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
import UserNotifications

enum BackgroundRefresh {
    /// In Info.plist's BGTaskSchedulerPermittedIdentifiers.
    static let id = "nl.w4j.doma.refresh"

    /// Registers the handler; once, before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
            // the handler runs on the main queue, so the task is on the main actor already
            nonisolated(unsafe) let refresh = task as? BGAppRefreshTask
            MainActor.assumeIsolated {
                if let refresh { run(refresh) }
            }
        }
    }

    /// One exchange on the main actor, where the task stays; the next run is asked for first.
    @MainActor private static func run(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { @MainActor in
            await Session.current?.syncer.sync()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Asks for the next run, about 15 minutes out.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// The app delegate: the push token and silent pushes.
final class PushDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundRefresh.register()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await Session.current?.registerPush(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // polling carries on; nothing to show
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // {"server": base_url, "household": id, "seq": n}: one exchange, within the 25 s budget
        await Session.current?.syncer.sync()
        return .newData
    }

    /// Registers for silent pushes and asks for the badge only.
    @MainActor static func enable() {
        UIApplication.shared.registerForRemoteNotifications()
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { _, _ in }
    }
}
#endif
