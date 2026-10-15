import Combine
import Foundation
import UserNotifications

@MainActor
final class TaskNotificationsManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var statusMessage: String?
    private let repository: DocumentTaskRepository
    private let center: UNUserNotificationCenter
    private let enabled: Bool
    private var observer: NSObjectProtocol?
    private var synchronization: Task<Void, Never>?
    private var needsSynchronization = false
    private struct ScheduleSignature: Equatable {
        var documentID: String
        var title: String
        var text: String
        var date: Double?
    }
    private var knownSchedules: [String: ScheduleSignature] = [:]
    var openDocument: ((String) -> Void)?

    init(repository: DocumentTaskRepository, database: AppDatabase, center: UNUserNotificationCenter = .current()) {
        self.repository = repository
        self.center = center
        self.enabled = !database.isInMemory
        super.init()
        if enabled { center.delegate = self }
        observer = NotificationCenter.default.addObserver(forName: .vellixTasksChanged, object: database, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func authorizeReminder() async -> String? {
        guard enabled else { return nil }
        do {
            let settings = await center.notificationSettings()
            let allowed: Bool
            if settings.authorizationStatus == .notDetermined {
                allowed = try await center.requestAuthorization(options: [.alert, .sound])
            } else {
                allowed = Self.permitted(settings.authorizationStatus)
            }
            refresh()
            return allowed ? nil : "Reminder saved. Notifications are disabled for Vellix in Settings."
        } catch {
            return "Reminder saved, but notification permission could not be requested: \(error.localizedDescription)"
        }
    }

    // Serialize reconciliation. A write arriving during an awaited system call gets another pass.
    func refresh() {
        guard enabled else { return }
        if let tasks = try? repository.all() {
            let current = Dictionary(uniqueKeysWithValues: tasks.filter { !$0.checked && $0.metadata.reminderEnabled }.map {
                ($0.metadata.notificationID, ScheduleSignature(documentID: $0.documentID, title: $0.documentTitle,
                                                                text: $0.text, date: $0.metadata.scheduledAt))
            })
            let obsolete = knownSchedules.keys.filter { knownSchedules[$0] != current[$0] }
            center.removePendingNotificationRequests(withIdentifiers: Array(obsolete))
            center.removeDeliveredNotifications(withIdentifiers: Array(obsolete))
            knownSchedules = current
        }
        needsSynchronization = true
        guard synchronization == nil else { return }
        synchronization = Task { [weak self] in
            guard let self else { return }
            while self.needsSynchronization {
                self.needsSynchronization = false
                await self.synchronize()
            }
            self.synchronization = nil
        }
    }

    func flush() async {
        refresh()
        while let synchronization { await synchronization.value }
    }

    private func synchronize() async {
        do {
            let settings = await center.notificationSettings()
            let permitted = Self.permitted(settings.authorizationStatus)
            let tasks = try repository.all().filter {
                !$0.checked && $0.metadata.reminderEnabled && ($0.metadata.scheduledDate.map { $0 > Date() } ?? false)
            }.sorted { ($0.metadata.scheduledAt ?? 0) < ($1.metadata.scheduledAt ?? 0) }
            // Keep room for non-task notifications within iOS's pending-request limit.
            let pending = await center.pendingNotificationRequests()
            let otherCount = pending.filter { !$0.identifier.hasPrefix("vellix.task.") }.count
            let capacity = min(60, max(0, 64 - otherCount))
            let selected = permitted ? Array(tasks.prefix(capacity)) : []
            let desired = Set(selected.map { $0.metadata.notificationID })
            let existing = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
            center.removePendingNotificationRequests(withIdentifiers: pending.filter {
                $0.identifier.hasPrefix("vellix.task.") && !desired.contains($0.identifier)
            }.map(\.identifier))
            let delivered = await center.deliveredNotifications()
            let active = Set(try repository.all().filter { !$0.checked && $0.metadata.reminderEnabled }.map { $0.metadata.notificationID })
            center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
                $0.request.identifier.hasPrefix("vellix.task.") && !active.contains($0.request.identifier)
            }.map { $0.request.identifier })
            for task in selected {
                guard let date = task.metadata.scheduledDate else { continue }
                let content = UNMutableNotificationContent()
                content.title = task.documentTitle
                content.body = task.text.isEmpty ? "Task reminder" : task.text
                content.sound = .default
                content.threadIdentifier = task.documentID
                content.userInfo = ["documentID": task.documentID, "taskID": task.id,
                                    "blockID": task.blockID, "occurrenceID": task.metadata.occurrenceID,
                                    "scheduledAt": date.timeIntervalSince1970]
                if let old = existing[task.metadata.notificationID], old.content.title == content.title,
                   old.content.body == content.body,
                   (old.content.userInfo["scheduledAt"] as? Double) == date.timeIntervalSince1970 { continue }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                components.timeZone = calendar.timeZone
                components.calendar = calendar
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                try await center.add(UNNotificationRequest(identifier: task.metadata.notificationID, content: content, trigger: trigger))
            }
            statusMessage = permitted && tasks.count > selected.count
                ? "The next \(selected.count) task reminders are scheduled. Later reminders are refreshed when Vellix opens." : nil
        } catch {
            statusMessage = "Task notifications could not be updated: \(error.localizedDescription)"
        }
    }

    private static func permitted(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional: return true
        #if os(iOS)
        case .ephemeral: return true
        #endif
        default: return false
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        guard id.hasPrefix("vellix.task.") else { completionHandler([.banner, .sound, .list]); return }
        Task { @MainActor [weak self] in
            let current = (try? self?.repository.all()) ?? []
            let valid = current.contains { !$0.checked && $0.metadata.reminderEnabled && $0.metadata.notificationID == id }
            completionHandler(valid ? [.banner, .sound, .list] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["documentID"] as? String
        Task { @MainActor [weak self] in
            if let id { self?.openDocument?(id) }
            self?.refresh()
        }
        completionHandler()
    }
}
