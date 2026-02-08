import AppKit
import ApplicationServices
import Carbon
import IOKit
import IOKit.hid
import IOKit.hidsystem

private final class CapsLockLightController {
    private let eventHandle: NXEventHandle
    private let hasEventHandle: Bool

    init() {
        eventHandle = NXOpenEventStatus()
        hasEventHandle = eventHandle != NXEventHandle(MACH_PORT_NULL)
    }

    deinit {
        if hasEventHandle {
            NXCloseEventStatus(eventHandle)
        }
    }

    func currentState() -> Bool? {
        guard hasEventHandle else { return nil }

        var state = false
        let result = IOHIDGetModifierLockState(eventHandle, Int32(kIOHIDCapsLockState), &state)
        guard result == KERN_SUCCESS else {
            return nil
        }
        return state
    }

    @discardableResult
    func setState(_ enabled: Bool) -> Bool {
        guard hasEventHandle else { return false }

        let result = IOHIDSetModifierLockState(eventHandle, Int32(kIOHIDCapsLockState), enabled)
        return result == KERN_SUCCESS
    }
}

private final class CapsLockPressWatcher {
    enum Error: Swift.Error {
        case unableToOpenHIDManager
    }

    private static let capsLockUsagePage = UInt32(kHIDPage_KeyboardOrKeypad)
    private static let capsLockUsage = UInt32(kHIDUsage_KeyboardCapsLock)

    private var hidManager: IOHIDManager?
    private var isRunning = false
    private var previousCapsValue = 0

    var onCapsLockPressed: (() -> Void)?

    func start() throws {
        guard !isRunning else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Int] = [
            kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop),
            kIOHIDDeviceUsageKey: Int(kHIDUsage_GD_Keyboard),
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let callback: IOHIDValueCallback = { context, _, _, value in
            guard let context else { return }
            let watcher = Unmanaged<CapsLockPressWatcher>.fromOpaque(context).takeUnretainedValue()
            watcher.handle(value: value)
        }

        IOHIDManagerRegisterInputValueCallback(
            manager,
            callback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            throw Error.unableToOpenHIDManager
        }

        hidManager = manager
        isRunning = true
        previousCapsValue = 0
    }

    func stop() {
        guard isRunning, let hidManager else {
            previousCapsValue = 0
            isRunning = false
            self.hidManager = nil
            return
        }

        IOHIDManagerRegisterInputValueCallback(hidManager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = nil
        isRunning = false
        previousCapsValue = 0
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)

        guard
            usagePage == Self.capsLockUsagePage,
            usage == Self.capsLockUsage
        else {
            return
        }

        let normalizedValue = IOHIDValueGetIntegerValue(value) > 0 ? 1 : 0
        defer { previousCapsValue = normalizedValue }

        guard normalizedValue == 1, previousCapsValue == 0 else {
            return
        }

        onCapsLockPressed?()
    }
}

final class CapsLockRemapper {
    enum Error: Swift.Error, LocalizedError {
        case unableToCreateEventTap
        case unableToCreateRunLoopSource
        case unableToOpenHIDManager

        var errorDescription: String? {
            switch self {
            case .unableToCreateEventTap:
                return "Could not create keyboard event tap. Check Accessibility and Input Monitoring permissions."
            case .unableToCreateRunLoopSource:
                return "Could not create run loop source for keyboard event tap."
            case .unableToOpenHIDManager:
                return "Could not open HID manager for Caps Lock press monitoring."
            }
        }
    }

    private static let capsLockKeyCode: CGKeyCode = 57
    private let letterKeyCodes: Set<CGKeyCode> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
        11, 12, 13, 14, 15, 16, 17, 31, 32, 34,
        35, 37, 38, 40, 45, 46,
    ]

    private static let keyEventMask: CGEventMask = {
        let types: [CGEventType] = [.keyDown, .flagsChanged]
        return types.reduce(0) { result, type in
            result | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
    }()

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let remapper = Unmanaged<CapsLockRemapper>.fromOpaque(userInfo).takeUnretainedValue()
        return remapper.handle(eventType: type, event: event)
    }

    private final class InputSourceController {
        private let preferredASCIIInputSourceIDs = [
            "com.apple.keylayout.ABC",
            "com.apple.keylayout.US",
        ]
        private let keyboardLayoutSourceType = kTISTypeKeyboardLayout as String
        private let chinesePinyinBundleIDs: Set<String> = [
            "com.apple.inputmethod.SCIM",
            "com.apple.inputmethod.TCIM",
        ]

        func enterCapsMode() -> String? {
            guard
                let currentSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                let currentSourceID = inputSourceID(for: currentSource)
            else {
                return nil
            }

            guard shouldSwitchToASCII(currentSource) else {
                return nil
            }

            guard
                let asciiSource = bestASCIISource(),
                let asciiSourceID = inputSourceID(for: asciiSource),
                asciiSourceID != currentSourceID
            else {
                return nil
            }

            _ = TISSelectInputSource(asciiSource)
            return currentSourceID
        }

        func exitCapsMode(restoreSourceID: String?) {
            guard
                let restoreSourceID,
                let previousSource = inputSource(withID: restoreSourceID)
            else {
                return
            }

            _ = TISSelectInputSource(previousSource)
        }

        private func bestASCIISource() -> TISInputSource? {
            if
                let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
                isASCIICapable(source),
                isSelectCapable(source),
                isKeyboardLayout(source)
            {
                return source
            }

            for sourceID in preferredASCIIInputSourceIDs {
                if
                    let source = inputSource(withID: sourceID),
                    isASCIICapable(source),
                    isSelectCapable(source),
                    isKeyboardLayout(source)
                {
                    return source
                }
            }

            let filter: [CFString: Any] = [
                kTISPropertyInputSourceType: kTISTypeKeyboardLayout as Any,
                kTISPropertyInputSourceIsASCIICapable: kCFBooleanTrue as Any,
                kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue as Any,
            ]

            guard
                let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource]
            else {
                return nil
            }

            return list.first
        }

        private func inputSource(withID id: String) -> TISInputSource? {
            let filter: [CFString: Any] = [kTISPropertyInputSourceID: id]
            guard
                let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource]
            else {
                return nil
            }
            return list.first
        }

        private func inputSourceID(for source: TISInputSource) -> String? {
            stringProperty(source, key: kTISPropertyInputSourceID)
        }

        private func shouldSwitchToASCII(_ source: TISInputSource) -> Bool {
            if isChinesePinyinSource(source) {
                return true
            }

            let alreadyASCIILayout = isASCIICapable(source) && isKeyboardLayout(source)
            return !alreadyASCIILayout
        }

        private func isChinesePinyinSource(_ source: TISInputSource) -> Bool {
            guard let bundleID = stringProperty(source, key: kTISPropertyBundleID) else {
                return false
            }
            return chinesePinyinBundleIDs.contains(bundleID)
        }

        private func isASCIICapable(_ source: TISInputSource) -> Bool {
            booleanProperty(source, key: kTISPropertyInputSourceIsASCIICapable)
        }

        private func isSelectCapable(_ source: TISInputSource) -> Bool {
            booleanProperty(source, key: kTISPropertyInputSourceIsSelectCapable)
        }

        private func isKeyboardLayout(_ source: TISInputSource) -> Bool {
            guard let rawValue = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
                return false
            }
            let inputSourceType = Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
            return inputSourceType == keyboardLayoutSourceType
        }

        private func booleanProperty(_ source: TISInputSource, key: CFString) -> Bool {
            guard let rawValue = TISGetInputSourceProperty(source, key) else {
                return false
            }
            let cfBoolean = Unmanaged<CFBoolean>.fromOpaque(rawValue).takeUnretainedValue()
            return CFBooleanGetValue(cfBoolean)
        }

        private func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
            guard let rawValue = TISGetInputSourceProperty(source, key) else {
                return nil
            }
            return Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var remapperRunning = false
    private var featureEnabled = false
    private var savedInputSourceID: String?
    private enum RuntimeWarning: String {
        case unableToReadKeycapLight = "Could not read Caps Lock keycap light; using internal instant mode state."
        case unableToSyncKeycapLight = "Could not synchronize Caps Lock keycap light; instant mode still works."
    }
    private var runtimeWarning: RuntimeWarning? {
        didSet {
            guard oldValue != runtimeWarning else { return }
            onWarningChanged?(runtimeWarning?.rawValue)
        }
    }

    private let capsLockPressWatcher = CapsLockPressWatcher()
    private let capsLockLightController = CapsLockLightController()
    private let inputSourceController = InputSourceController()

    private(set) var capsModeEnabled = false {
        didSet {
            guard oldValue != capsModeEnabled else {
                return
            }
            onCapsModeChanged?(capsModeEnabled)
        }
    }

    var onCapsModeChanged: ((Bool) -> Void)?
    var onWarningChanged: ((String?) -> Void)?

    deinit {
        stop()
    }

    func start() throws {
        guard !remapperRunning else { return }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.keyEventMask,
            callback: Self.eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            throw Error.unableToCreateEventTap
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw Error.unableToCreateRunLoopSource
        }

        capsLockPressWatcher.onCapsLockPressed = { [weak self] in
            self?.handleCapsLockPressed()
        }
        do {
            try capsLockPressWatcher.start()
        } catch {
            capsLockPressWatcher.onCapsLockPressed = nil
            throw Error.unableToOpenHIDManager
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        remapperRunning = true
    }

    func stop() {
        guard remapperRunning else { return }

        setFeatureEnabled(false)
        capsLockPressWatcher.stop()
        capsLockPressWatcher.onCapsLockPressed = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        remapperRunning = false
    }

    private func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch eventType {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return pass(event)

        case .flagsChanged:
            return handleFlagsChanged(event)

        case .keyDown:
            return handleKeyEvent(event)

        default:
            return pass(event)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if featureEnabled, keyCode == Self.capsLockKeyCode {
            return nil
        }

        removeSystemCapsFlagIfNeeded(event)
        return pass(event)
    }

    private func handleKeyEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        removeSystemCapsFlagIfNeeded(event)

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isLetterKey = letterKeyCodes.contains(keyCode)
        let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]

        guard featureEnabled, capsModeEnabled else {
            return pass(event)
        }

        guard event.type == .keyDown else {
            return pass(event)
        }

        guard isLetterKey else {
            return pass(event)
        }

        var flags = event.flags
        let shiftWasPressed = flags.contains(.maskShift)
        if !flags.intersection(shortcutModifiers).isEmpty {
            return pass(event)
        }

        if flags.contains(.maskShift) {
            flags.remove(.maskShift)
        } else {
            flags.insert(.maskShift)
        }
        flags.remove(.maskAlphaShift)
        event.flags = flags

        forceASCIILetterCase(event, uppercase: !shiftWasPressed)

        return pass(event)
    }

    private func forceASCIILetterCase(_ event: CGEvent, uppercase: Bool) {
        var actualLength = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &actualLength,
            unicodeString: &buffer
        )

        guard actualLength == 1 else { return }
        let value = buffer[0]
        let isLowercaseASCII = value >= 97 && value <= 122
        let isUppercaseASCII = value >= 65 && value <= 90
        guard isLowercaseASCII || isUppercaseASCII else { return }

        var transformed = value
        if uppercase && isLowercaseASCII {
            transformed -= 32
        } else if !uppercase && isUppercaseASCII {
            transformed += 32
        }

        event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &transformed)
    }

    func setFeatureEnabled(_ enabled: Bool) {
        guard featureEnabled != enabled else {
            return
        }

        featureEnabled = enabled
        if featureEnabled {
            runtimeWarning = nil
            let currentLightState = capsLockLightController.currentState()
            let initialCapsMode = currentLightState ?? false
            if currentLightState == nil {
                runtimeWarning = .unableToReadKeycapLight
            }
            setCapsMode(initialCapsMode, syncHardwareLight: false)
        } else {
            setCapsMode(false, syncHardwareLight: true)
            runtimeWarning = nil
        }
    }

    private func handleCapsLockPressed() {
        guard featureEnabled else { return }
        setCapsMode(!capsModeEnabled, syncHardwareLight: true)
    }

    private func setCapsMode(_ enabled: Bool, syncHardwareLight: Bool) {
        guard capsModeEnabled != enabled else {
            return
        }

        capsModeEnabled = enabled
        if enabled {
            savedInputSourceID = inputSourceController.enterCapsMode()
        } else {
            inputSourceController.exitCapsMode(restoreSourceID: savedInputSourceID)
            savedInputSourceID = nil
        }

        if syncHardwareLight {
            if capsLockLightController.setState(enabled) {
                if runtimeWarning == .unableToSyncKeycapLight {
                    runtimeWarning = nil
                }
            } else {
                runtimeWarning = .unableToSyncKeycapLight
            }
        }
    }

    private func removeSystemCapsFlagIfNeeded(_ event: CGEvent) {
        guard featureEnabled else { return }
        var flags = event.flags
        guard flags.contains(.maskAlphaShift) else { return }
        flags.remove(.maskAlphaShift)
        event.flags = flags
    }

    private func pass(_ event: CGEvent) -> Unmanaged<CGEvent> {
        Unmanaged.passUnretained(event)
    }
}

enum PermissionHelper {
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func hasInputMonitoringPermission() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func promptForAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func promptForInputMonitoringPermission() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

@MainActor
final class ControlsWindowController: NSWindowController, NSWindowDelegate {
    var onToggleEnabled: ((Bool) -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onOpenInputMonitoring: (() -> Void)?
    var onWindowClosed: (() -> Void)?

    private let enableCheckbox = NSButton(
        checkboxWithTitle: "Enable instant Caps Lock",
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CapsLock Fix"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setInstantCapsEnabled(_ enabled: Bool) {
        enableCheckbox.state = enabled ? .on : .off
    }

    func setStatus(text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "CapsLock Fix")
        titleLabel.font = NSFont.systemFont(ofSize: 24, weight: .semibold)

        let subtitleLabel = NSTextField(
            wrappingLabelWithString: "When enabled, Caps Lock toggles instantly for English and Chinese Pinyin input. When disabled, macOS default behavior is unchanged."
        )
        subtitleLabel.textColor = .secondaryLabelColor

        enableCheckbox.target = self
        enableCheckbox.action = #selector(toggleCheckboxChanged)
        enableCheckbox.font = NSFont.systemFont(ofSize: 14, weight: .medium)

        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor

        let openAccessibilityButton = NSButton(
            title: "Open Accessibility",
            target: self,
            action: #selector(openAccessibilityClicked)
        )

        let openInputMonitoringButton = NSButton(
            title: "Open Input Monitoring",
            target: self,
            action: #selector(openInputMonitoringClicked)
        )

        let buttonStack = NSStackView(views: [openAccessibilityButton, openInputMonitoringButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .leading
        buttonStack.spacing = 10

        let stack = NSStackView(views: [titleLabel, subtitleLabel, enableCheckbox, statusLabel, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    @objc private func toggleCheckboxChanged() {
        onToggleEnabled?(enableCheckbox.state == .on)
    }

    @objc private func openAccessibilityClicked() {
        onOpenAccessibility?()
    }

    @objc private func openInputMonitoringClicked() {
        onOpenInputMonitoring?()
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let enabledPreferenceKey = "InstantCapsEnabled"

    private let remapper = CapsLockRemapper()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusContextMenu = NSMenu()
    private let toggleMenuItem = NSMenuItem(title: "Turn On CapsLock Fix", action: #selector(toggleFromMenu), keyEquivalent: "")
    private let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")

    private var isInstantCapsEnabled: Bool
    private var remapperRunning = false
    private var lastHookError: String?
    private var remapperWarning: String?
    private var controlsWindowController: ControlsWindowController!

    override init() {
        let defaults = UserDefaults.standard
        isInstantCapsEnabled = defaults.object(forKey: Self.enabledPreferenceKey) as? Bool ?? false
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installStatusItem()
        installContextMenu()
        installControlsWindow()

        remapper.onCapsModeChanged = { [weak self] enabled in
            DispatchQueue.main.async {
                self?.refreshUI(capsModeEnabled: enabled)
            }
        }
        remapper.onWarningChanged = { [weak self] warning in
            DispatchQueue.main.async {
                self?.remapperWarning = warning
                self?.refreshUI(capsModeEnabled: self?.remapper.capsModeEnabled ?? false)
            }
        }

        applyInstantCapsSetting(promptForPermission: false)
        showControls()
    }

    func applicationWillTerminate(_ notification: Notification) {
        remapper.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "CapsLock Fix"
    }

    private func installContextMenu() {
        toggleMenuItem.target = self
        quitMenuItem.target = self
        statusContextMenu.addItem(toggleMenuItem)
        statusContextMenu.addItem(.separator())
        statusContextMenu.addItem(quitMenuItem)
    }

    private func installControlsWindow() {
        controlsWindowController = ControlsWindowController()
        controlsWindowController.onToggleEnabled = { [weak self] enabled in
            self?.setInstantCapsEnabled(enabled, promptForPermission: enabled)
        }
        controlsWindowController.onOpenAccessibility = { [weak self] in
            self?.openAccessibilitySettings()
        }
        controlsWindowController.onOpenInputMonitoring = { [weak self] in
            self?.openInputMonitoringSettings()
        }
        controlsWindowController.onWindowClosed = { [weak self] in
            self?.hideDockIcon()
        }
    }

    private func setInstantCapsEnabled(_ enabled: Bool, promptForPermission: Bool) {
        isInstantCapsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledPreferenceKey)
        applyInstantCapsSetting(promptForPermission: promptForPermission)
    }

    private func applyInstantCapsSetting(promptForPermission: Bool) {
        if isInstantCapsEnabled {
            if promptForPermission {
                PermissionHelper.promptForAccessibilityPermission()
                PermissionHelper.promptForInputMonitoringPermission()
            }

            do {
                try remapper.start()
                remapper.setFeatureEnabled(true)
                remapperRunning = true
                lastHookError = nil
            } catch {
                remapperRunning = false
                remapperWarning = nil
                if PermissionHelper.hasAccessibilityPermission() && PermissionHelper.hasInputMonitoringPermission() {
                    lastHookError = "Keyboard hook failed: \(error.localizedDescription)"
                } else {
                    lastHookError = "Permission required: enable Accessibility and Input Monitoring."
                }
            }
        } else {
            remapper.stop()
            remapperRunning = false
            lastHookError = nil
            remapperWarning = nil
        }

        refreshUI(capsModeEnabled: remapper.capsModeEnabled)
    }

    private func refreshUI(capsModeEnabled: Bool) {
        controlsWindowController?.setInstantCapsEnabled(isInstantCapsEnabled)
        toggleMenuItem.title = isInstantCapsEnabled ? "Turn Off CapsLock Fix" : "Turn On CapsLock Fix"

        if !isInstantCapsEnabled {
            let text = "System default Caps Lock behavior (instant mode is off)."
            controlsWindowController?.setStatus(text: text, isError: false)
            setStatusBarIcon(mode: .disabled)
            return
        }

        if remapperRunning {
            let capsText = capsModeEnabled ? "Caps mode ON" : "Caps mode OFF"
            var statusText = "Instant mode is active. Press Caps Lock to toggle immediately (\(capsText))."
            if let remapperWarning {
                statusText += "\n\(remapperWarning)"
            }
            controlsWindowController?.setStatus(
                text: statusText,
                isError: false
            )
            if remapperWarning != nil {
                setStatusBarIcon(mode: .warning)
            } else {
                setStatusBarIcon(mode: capsModeEnabled ? .enabledCapsOn : .enabledCapsOff)
            }
        } else {
            let errorText = lastHookError ?? "Keyboard hook unavailable."
            controlsWindowController?.setStatus(text: errorText, isError: true)
            setStatusBarIcon(mode: .error)
        }
    }

    private enum StatusIconMode {
        case disabled
        case enabledCapsOff
        case enabledCapsOn
        case warning
        case error
    }

    private func setStatusBarIcon(mode: StatusIconMode) {
        let symbolName: String
        switch mode {
        case .disabled:
            symbolName = "capslock"
        case .enabledCapsOff:
            symbolName = "capslock"
        case .enabledCapsOn:
            symbolName = "capslock.fill"
        case .warning:
            symbolName = "exclamationmark.triangle"
        case .error:
            symbolName = "exclamationmark.triangle"
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        if
            let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CapsLock Fix"),
            let configuredImage = baseImage.withSymbolConfiguration(symbolConfig)
        {
            configuredImage.isTemplate = true
            statusItem.button?.image = configuredImage
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = mode == .enabledCapsOn ? "CAPS" : "caps"
        }
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else {
            showControls()
            return
        }

        if event.type == .rightMouseUp {
            statusItem.menu = statusContextMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            showControls()
        }
    }

    @objc private func showControls() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        controlsWindowController.showWindow(nil)
        controlsWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hideDockIcon() {
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func toggleFromMenu() {
        setInstantCapsEnabled(!isInstantCapsEnabled, promptForPermission: !isInstantCapsEnabled)
    }

    @objc private func openAccessibilitySettings() {
        PermissionHelper.promptForAccessibilityPermission()
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openInputMonitoringSettings() {
        PermissionHelper.promptForInputMonitoringPermission()
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func openSettings(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
