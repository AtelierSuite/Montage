import MontageEngine
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Says when an export finishes or fails while the app isn't in front.
@MainActor
final class ExportNotifier: ExportQueueObserver {
    private var hasAskedForPermission = false

    func exportWillStart(_ job: ExportJob) {
        // Asked when the user first exports, when it's clear what for.
        guard !hasAskedForPermission else { return }
        hasAskedForPermission = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    func exportDidProgress(_ job: ExportJob) {}

    func exportDidEnd(_ job: ExportJob) {
        guard !Self.isAppInFront else { return }
        let content = UNMutableNotificationContent()
        switch job.state {
        case .finished:
            content.title = String(localized: "Export.Notification.Finished")
        case .readyToSave:
            content.title = String(localized: "Export.Notification.ReadyToSave")
        case .failed(let message):
            content.title = String(localized: "Export.Notification.Failed")
            content.body = message
        case .queued, .rendering, .delivering, .cancelled:
            return
        }
        content.subtitle = job.fileName
        content.sound = .default
        let request = UNNotificationRequest(identifier: "export.\(job.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static var isAppInFront: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        NSApp.isActive
        #endif
    }
}
