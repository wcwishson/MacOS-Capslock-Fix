import Foundation
import ApplicationServices
import Carbon

@MainActor
final class WindowSpecificInputMemory {
    var onStatusChanged: ((String?) -> Void)?

    private let inputSources = WindowInputSourceController()
    private let pollInterval: TimeInterval = 0.15
    private var pollTimer: Timer?
    private var notificationObservers: [NSObjectProtocol] = []
    private var isRunning = false
    private var isPaused = false
    private var focusedWindowKey: WindowMemoryKey?
    private var windowInputSources: [WindowMemoryKey: String] = [:]
    private var suppressedSelectedSourceID: String?
    private var lastStatus: String?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installInputSourceObserver()
        startPolling()
        refreshFocusedWindow(savePrevious: false)
        updateStatus()
    }

    func stop() {
        guard isRunning else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        removeInputSourceObservers()
        focusedWindowKey = nil
        suppressedSelectedSourceID = nil
        windowInputSources.removeAll()
        isRunning = false
        updateStatus(nil)
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        if paused {
            saveCurrentFocusedWindowSource()
        }

        isPaused = paused
        suppressedSelectedSourceID = nil

        if paused {
            updateStatus("Window-specific input memory is paused while Caps mode is ON.")
        } else {
            focusedWindowKey = nil
            refreshFocusedWindow(savePrevious: false)
            updateStatus()
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(
            timeInterval: pollInterval,
            target: self,
            selector: #selector(handlePollTimer(_:)),
            userInfo: nil,
            repeats: true
        )
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    @objc private func handlePollTimer(_ timer: Timer) {
        _ = timer
        refreshFocusedWindow(savePrevious: true)
    }

    private func refreshFocusedWindow(savePrevious: Bool) {
        guard isRunning, !isPaused else { return }

        guard AXIsProcessTrusted() else {
            focusedWindowKey = nil
            updateStatus("Window-specific input memory needs Accessibility permission.")
            return
        }

        guard let currentWindow = FocusedWindowSnapshot.current(), currentWindow.pid != ProcessInfo.processInfo.processIdentifier else {
            focusedWindowKey = nil
            updateStatus()
            return
        }

        let previousFocusedKey = focusedWindowKey
        guard previousFocusedKey != currentWindow.key else {
            return
        }

        if savePrevious,
           let previousFocusedKey,
           let currentSourceID = inputSources.currentSourceID(),
           inputSources.canSelectSource(id: currentSourceID)
        {
            windowInputSources[previousFocusedKey] = currentSourceID
        }

        focusedWindowKey = currentWindow.key
        if windowInputSources[currentWindow.key] == nil, let currentSourceID = inputSources.currentSourceID() {
            windowInputSources[currentWindow.key] = currentSourceID
        }

        restoreInputSource(for: currentWindow.key)
        updateStatus()
    }

    private func saveCurrentFocusedWindowSource() {
        guard isRunning else { return }
        guard let currentSourceID = inputSources.currentSourceID(), inputSources.canSelectSource(id: currentSourceID) else { return }

        if let currentWindow = FocusedWindowSnapshot.current(), currentWindow.pid != ProcessInfo.processInfo.processIdentifier {
            focusedWindowKey = currentWindow.key
            windowInputSources[currentWindow.key] = currentSourceID
        } else if let focusedWindowKey {
            windowInputSources[focusedWindowKey] = currentSourceID
        }
    }

    private func restoreInputSource(for key: WindowMemoryKey) {
        guard !isPaused, let targetSourceID = windowInputSources[key] else { return }
        guard inputSources.canSelectSource(id: targetSourceID) else { return }
        guard inputSources.currentSourceID() != targetSourceID else { return }

        suppressedSelectedSourceID = targetSourceID
        if !inputSources.selectSource(id: targetSourceID) {
            suppressedSelectedSourceID = nil
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.suppressedSelectedSourceID == targetSourceID else { return }
            self.suppressedSelectedSourceID = nil
        }
    }

    private func installInputSourceObserver() {
        removeInputSourceObservers()
        let center = DistributedNotificationCenter.default()
        guard let name = WindowInputSourceController.selectedSourceChangedNotificationName else { return }

        let observer = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleInputSourceChanged()
            }
        }
        notificationObservers = [observer]
    }

    private func removeInputSourceObservers() {
        let center = DistributedNotificationCenter.default()
        notificationObservers.forEach { center.removeObserver($0) }
        notificationObservers.removeAll()
    }

    private func handleInputSourceChanged() {
        guard isRunning, !isPaused else { return }
        guard let selectedID = inputSources.currentSourceID() else { return }

        if suppressedSelectedSourceID == selectedID {
            suppressedSelectedSourceID = nil
            return
        }

        if let currentWindow = FocusedWindowSnapshot.current() {
            focusedWindowKey = currentWindow.key
            windowInputSources[currentWindow.key] = selectedID
            updateStatus()
        }
    }

    private func updateStatus(_ explicitStatus: String? = nil) {
        let status: String?
        if let explicitStatus {
            status = explicitStatus
        } else if isRunning {
            status = "Window-specific input memory is active for normal typing."
        } else {
            status = nil
        }

        guard status != lastStatus else { return }
        lastStatus = status
        onStatusChanged?(status)
    }
}

private struct WindowMemoryKey: Hashable {
    let pid: pid_t
    let token: UInt64
}

private struct FocusedWindowSnapshot {
    let key: WindowMemoryKey
    let pid: pid_t

    static func current() -> FocusedWindowSnapshot? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedAppValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppValue
        ) == .success, let focusedAppValue else {
            return nil
        }

        let focusedApp = focusedAppValue as! AXUIElement
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedApp,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success, let focusedWindowValue else {
            return nil
        }

        let focusedWindow = focusedWindowValue as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(focusedWindow, &pid)
        guard pid != 0 else { return nil }

        let token = windowNumber(from: focusedWindow) ?? UInt64(bitPattern: Int64(CFHash(focusedWindow)))
        guard token != 0 else { return nil }
        return FocusedWindowSnapshot(key: WindowMemoryKey(pid: pid, token: token), pid: pid)
    }

    private static func windowNumber(from window: AXUIElement) -> UInt64? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success, let value else {
            return nil
        }

        if let number = value as? NSNumber {
            let raw = number.int64Value
            return raw > 0 ? UInt64(raw) : nil
        }

        if CFGetTypeID(value) == CFNumberGetTypeID() {
            var rawValue: Int64 = 0
            if CFNumberGetValue((value as! CFNumber), .sInt64Type, &rawValue), rawValue > 0 {
                return UInt64(rawValue)
            }
        }

        return nil
    }
}

@MainActor
private final class WindowInputSourceController {
    static var selectedSourceChangedNotificationName: Notification.Name? {
        guard let value = kTISNotifySelectedKeyboardInputSourceChanged else { return nil }
        return Notification.Name(rawValue: value as String)
    }

    func currentSourceID() -> String? {
        guard let unmanagedCurrent = TISCopyCurrentKeyboardInputSource() else { return nil }
        let current = unmanagedCurrent.takeRetainedValue()
        return stringProperty(current, key: kTISPropertyInputSourceID)
    }

    func canSelectSource(id: String) -> Bool {
        guard let source = inputSource(for: id) else { return false }
        return boolProperty(source, key: kTISPropertyInputSourceIsEnabled)
            && boolProperty(source, key: kTISPropertyInputSourceIsSelectCapable)
    }

    func selectSource(id: String) -> Bool {
        guard let source = inputSource(for: id), canSelectSource(id: id) else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private func inputSource(for id: String) -> TISInputSource? {
        let filter: [String: Any] = [kTISPropertyInputSourceID as String: id]
        guard let unmanagedList = TISCreateInputSourceList(filter as CFDictionary, false) else { return nil }
        let list = unmanagedList.takeRetainedValue()
        return (list as? [TISInputSource])?.first
    }

    private func propertyValue(_ source: TISInputSource, key: CFString) -> AnyObject? {
        guard let rawPointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(rawPointer).takeUnretainedValue()
    }

    private func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        if let string = propertyValue(source, key: key) as? String { return string }
        if let nsString = propertyValue(source, key: key) as? NSString { return nsString as String }
        return nil
    }

    private func boolProperty(_ source: TISInputSource, key: CFString) -> Bool {
        if let value = propertyValue(source, key: key) as? Bool { return value }
        if let number = propertyValue(source, key: key) as? NSNumber { return number.boolValue }
        return false
    }
}
