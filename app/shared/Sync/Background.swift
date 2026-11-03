// The phone's two ways to sync with the app off screen: a silent push from the server, and the
// system's background refresh about every 15 minutes. Push is a hint; a device that misses it
// catches up on the next trigger. A push may also carry words, when someone else added to a
// list or cleared it: the system shows them while the app is away, and the app shows nothing
// of its own while it is in front, it just syncs.
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

/// The app delegate: the push token, silent pushes, and what a visible one does.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundRefresh.register()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// A notification arriving while the app is in front: no banner, the list is already
    /// showing the change; one exchange so it shows now.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            await Session.current?.syncer.sync()
            completionHandler([])
        }
    }

    /// A tap on a notification opens the app; the list it names is the one in front already
    /// when it is the current list, and one exchange brings the rest.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        Task { @MainActor in
            await Session.current?.syncer.sync()
            completionHandler()
        }
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

    /// Registers for pushes and asks, once, to show the family's adds and clears and the
    /// badge; the system remembers the answer, and Settings says where to change it.
    @MainActor static func enable() {
        UIApplication.shared.registerForRemoteNotifications()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Whether the person lets the family's changes show as notifications.
    static func notificationsAllowed() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
#endif
