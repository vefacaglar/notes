import AppKit
import CoreGraphics

/// Locks the encrypted notes when the screen locks, the Mac goes to sleep, or there was no keyboard or mouse input
/// for the time set in Settings (docs/format.md, "Encrypted notes"). Quitting locks too (see `NotesModel`).
@MainActor
final class AutoLock {
    private let lock: @MainActor () -> Void
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: Timer?
    /// The idle lock already fired for the current stretch of inactivity (it fires once, not every poll).
    private var firedWhileIdle = false

    init(lock: @escaping @MainActor () -> Void) {
        self.lock = lock
        observe(DistributedNotificationCenter.default(), name: "com.apple.screenIsLocked")
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.willSleepNotification.rawValue)
        // Common modes: the idle lock must also fire while an alert, a save panel or a menu is up.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observe(_ center: NotificationCenter, name: String) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        observers.append((center, token))
    }

    private func poll() {
        let minutes = AppSettings.shared.lockEncryptedAfterMinutes
        guard minutes > 0 else {
            firedWhileIdle = false
            return
        }
        // All input event types: the time since the last key, click, move or scroll.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle < Double(minutes) * 60 {
            firedWhileIdle = false
        } else if !firedWhileIdle {
            firedWhileIdle = true
            lock()
        }
    }
}
