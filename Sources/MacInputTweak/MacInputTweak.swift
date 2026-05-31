import AppKit
import ApplicationServices
import IOKit
import IOKit.hid
import IOKit.hidsystem

private final class CapsLockLightController {
    private static let keyboardUsagePage = Int(kHIDPage_GenericDesktop)
    private static let keyboardUsage = Int(kHIDUsage_GD_Keyboard)
    private static let capsLockLEDUsagePage = UInt32(kHIDPage_LEDs)
    private static let capsLockLEDUsage = UInt32(kHIDUsage_LED_CapsLock)

    private let eventHandle: NXEventHandle
    private let hasEventHandle: Bool
    private var ledManager: IOHIDManager?
    private var capsLockLEDElements: [IOHIDElement] = []

    init() {
        eventHandle = NXOpenEventStatus()
        hasEventHandle = eventHandle != NXEventHandle(MACH_PORT_NULL)
        refreshLEDElements()
    }

    deinit {
        if let ledManager {
            IOHIDManagerClose(ledManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if hasEventHandle {
            NXCloseEventStatus(eventHandle)
        }
    }

    @discardableResult
    func setState(_ enabled: Bool) -> Bool {
        if setLEDState(enabled) {
            return true
        }

        guard hasEventHandle else { return false }
        let result = IOHIDSetModifierLockState(eventHandle, Int32(kIOHIDCapsLockState), enabled)
        return result == KERN_SUCCESS
    }

    private func refreshLEDElements() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Int] = [
            kIOHIDDeviceUsagePageKey: Self.keyboardUsagePage,
            kIOHIDDeviceUsageKey: Self.keyboardUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return
        }

        ledManager = manager
        capsLockLEDElements = Self.capsLockLEDElements(from: manager)
    }

    private func setLEDState(_ enabled: Bool) -> Bool {
        if capsLockLEDElements.isEmpty {
            refreshLEDElements()
        }

        var didSetAnyLED = false
        for element in capsLockLEDElements {
            let device = IOHIDElementGetDevice(element)
            let value = IOHIDValueCreateWithIntegerValue(
                kCFAllocatorDefault,
                element,
                0,
                enabled ? 1 : 0
            )
            let result = IOHIDDeviceSetValue(device, element, value)
            if result == kIOReturnSuccess {
                didSetAnyLED = true
            }
        }
        return didSetAnyLED
    }

    private static func capsLockLEDElements(from manager: IOHIDManager) -> [IOHIDElement] {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return []
        }

        var elements: [IOHIDElement] = []
        for device in devices {
            guard
                let deviceElements = IOHIDDeviceCopyMatchingElements(
                    device,
                    nil,
                    IOOptionBits(kIOHIDOptionsTypeNone)
                ) as? [IOHIDElement]
            else {
                continue
            }

            elements.append(contentsOf: deviceElements.filter { element in
                let type = IOHIDElementGetType(element)
                return IOHIDElementGetUsagePage(element) == capsLockLEDUsagePage
                    && IOHIDElementGetUsage(element) == capsLockLEDUsage
                    && (type == kIOHIDElementTypeOutput || type == kIOHIDElementTypeFeature)
            })
        }
        return elements
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

        var errorDescription: String? {
            switch self {
            case .unableToCreateEventTap:
                return "Could not create keyboard event tap. Check Accessibility and Input Monitoring permissions."
            case .unableToCreateRunLoopSource:
                return "Could not create run loop source for keyboard event tap."
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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var remapperRunning = false
    private var featureEnabled = false
    private var lastCapsLockPressTime: CFAbsoluteTime = 0
    private var rawCapsWatcherRunning = false
    private enum RuntimeWarning: String {
        case unableToSyncKeycapLight = "Could not synchronize Caps Lock keycap light; instant mode still works."
        case unableToOpenRawCapsWatcher = "Raw Caps Lock monitor unavailable; using event-tap fallback."
    }
    private var runtimeWarning: RuntimeWarning? {
        didSet {
            guard oldValue != runtimeWarning else { return }
            onWarningChanged?(runtimeWarning?.rawValue)
        }
    }

    private let capsLockPressWatcher = CapsLockPressWatcher()
    private let capsLockLightController = CapsLockLightController()

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
        if (try? capsLockPressWatcher.start()) == nil {
            capsLockPressWatcher.onCapsLockPressed = nil
            rawCapsWatcherRunning = false
            runtimeWarning = .unableToOpenRawCapsWatcher
        } else {
            rawCapsWatcherRunning = true
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
        rawCapsWatcherRunning = false

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
            if !rawCapsWatcherRunning {
                handleCapsLockPressed()
            }
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
        lastCapsLockPressTime = 0
        if featureEnabled {
            runtimeWarning = nil
            setCapsMode(false, syncHardwareLight: true)
        } else {
            setCapsMode(false, syncHardwareLight: true)
            runtimeWarning = nil
        }
    }

    private func handleCapsLockPressed() {
        guard featureEnabled else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCapsLockPressTime > 0.08 else { return }
        lastCapsLockPressTime = now

        setCapsMode(!capsModeEnabled, syncHardwareLight: true)
    }

    private func setCapsMode(_ enabled: Bool, syncHardwareLight: Bool) {
        let modeChanged = capsModeEnabled != enabled
        if modeChanged, !enabled, syncHardwareLight {
            syncKeycapLight(to: false)
        }

        if modeChanged {
            capsModeEnabled = enabled
        }

        if syncHardwareLight, enabled || !modeChanged {
            syncKeycapLight(to: enabled)
        }
    }

    private func syncKeycapLight(to enabled: Bool) {
        if capsLockLightController.setState(enabled) {
            if runtimeWarning == .unableToSyncKeycapLight {
                runtimeWarning = nil
            }
        } else {
            runtimeWarning = .unableToSyncKeycapLight
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
        CGPreflightListenEventAccess() || inputMonitoringAccess() == kIOHIDAccessTypeGranted
    }

    static func diagnosticSummary() -> String {
        let accessibility = hasAccessibilityPermission() ? "on" : "off"
        let hidAccess = inputMonitoringAccess()
        let inputMonitoring = hidAccess == kIOHIDAccessTypeGranted ? "on" : "off"
        let cgListen = CGPreflightListenEventAccess() ? "on" : "off"
        return "Accessibility: \(accessibility). Input Monitoring: \(inputMonitoring) (IOHID=\(inputMonitoringStatusName(hidAccess)), CGListen=\(cgListen))."
    }

    static func missingPermissionMessage() -> String? {
        let accessibilityGranted = hasAccessibilityPermission()
        let inputMonitoringGranted = hasInputMonitoringPermission()

        switch (accessibilityGranted, inputMonitoringGranted) {
        case (false, false):
            return "Accessibility and Input Monitoring are off for this app. Open both privacy pages and turn on Mac Input Tweak."
        case (false, true):
            return "Accessibility is off for this app. Open Accessibility and turn on Mac Input Tweak."
        case (true, false):
            return "Input Monitoring is off for this app. Open Input Monitoring and turn on Mac Input Tweak."
        case (true, true):
            return nil
        }
    }

    private static func inputMonitoringAccess() -> IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    private static func inputMonitoringStatusName(_ access: IOHIDAccessType) -> String {
        switch access {
        case kIOHIDAccessTypeGranted:
            return "granted"
        case kIOHIDAccessTypeDenied:
            return "denied"
        case kIOHIDAccessTypeUnknown:
            return "not requested"
        default:
            return "unknown"
        }
    }

    static func promptForAccessibilityPermission() {
        guard !hasAccessibilityPermission() else { return }
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func promptForInputMonitoringPermission() {
        guard !hasInputMonitoringPermission() else { return }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        _ = CGRequestListenEventAccess()
    }
}

@MainActor
final class ControlsWindowController: NSWindowController, NSWindowDelegate {
    var onToggleInstantCaps: ((Bool) -> Void)?
    var onToggleWindowInputMemory: ((Bool) -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onOpenInputMonitoring: (() -> Void)?
    var onWindowClosed: (() -> Void)?

    private let instantCapsCheckbox = NSButton(
        checkboxWithTitle: "Enable instant Caps Lock",
        target: nil,
        action: nil
    )
    private let windowInputMemoryCheckbox = NSButton(
        checkboxWithTitle: "Enable window-specific input memory",
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Input Tweak"
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

    func setFeatureStates(instantCapsEnabled: Bool, windowInputMemoryEnabled: Bool) {
        instantCapsCheckbox.state = instantCapsEnabled ? .on : .off
        windowInputMemoryCheckbox.state = windowInputMemoryEnabled ? .on : .off
    }

    func setStatus(text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Mac Input Tweak")
        titleLabel.font = NSFont.systemFont(ofSize: 24, weight: .semibold)

        let subtitleLabel = NSTextField(
            wrappingLabelWithString: "Small input fixes for macOS: instant Caps Lock typing and optional per-window input source memory."
        )
        subtitleLabel.textColor = .secondaryLabelColor

        instantCapsCheckbox.target = self
        instantCapsCheckbox.action = #selector(instantCapsCheckboxChanged)
        instantCapsCheckbox.font = NSFont.systemFont(ofSize: 14, weight: .medium)

        windowInputMemoryCheckbox.target = self
        windowInputMemoryCheckbox.action = #selector(windowInputMemoryCheckboxChanged)
        windowInputMemoryCheckbox.font = NSFont.systemFont(ofSize: 14, weight: .medium)

        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 7
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

        let stack = NSStackView(views: [titleLabel, subtitleLabel, instantCapsCheckbox, windowInputMemoryCheckbox, statusLabel, buttonStack])
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

    @objc private func instantCapsCheckboxChanged() {
        onToggleInstantCaps?(instantCapsCheckbox.state == .on)
    }

    @objc private func windowInputMemoryCheckboxChanged() {
        onToggleWindowInputMemory?(windowInputMemoryCheckbox.state == .on)
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
    private static let instantCapsPreferenceKey = "InstantCapsEnabled"
    private static let windowInputMemoryPreferenceKey = "WindowInputMemoryEnabled"

    private let remapper = CapsLockRemapper()
    private let windowSpecificInputMemory = WindowSpecificInputMemory()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusContextMenu = NSMenu()
    private let toggleInstantCapsMenuItem = NSMenuItem(title: "Turn On Instant Caps Lock", action: #selector(toggleInstantCapsFromMenu), keyEquivalent: "")
    private let toggleWindowInputMemoryMenuItem = NSMenuItem(title: "Turn On Window Input Memory", action: #selector(toggleWindowInputMemoryFromMenu), keyEquivalent: "")
    private let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")

    private var isInstantCapsEnabled: Bool
    private var isWindowInputMemoryEnabled: Bool
    private var remapperRunning = false
    private var lastHookError: String?
    private var remapperWarning: String?
    private var windowSpecificInputStatus: String?
    private var controlsWindowController: ControlsWindowController!
    private var permissionRetryTimer: Timer?
    private let startsHidden = ProcessInfo.processInfo.arguments.contains("--background")

    override init() {
        let defaults = UserDefaults.standard
        isInstantCapsEnabled = defaults.object(forKey: Self.instantCapsPreferenceKey) as? Bool ?? false
        isWindowInputMemoryEnabled = defaults.object(forKey: Self.windowInputMemoryPreferenceKey) as? Bool ?? false
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(startsHidden ? .accessory : .regular)
        installStatusItem()
        installContextMenu()
        installControlsWindow()

        remapper.onCapsModeChanged = { [weak self] enabled in
            DispatchQueue.main.async {
                if self?.isWindowInputMemoryEnabled == true {
                    self?.windowSpecificInputMemory.setPaused(enabled)
                }
                self?.refreshUI(capsModeEnabled: enabled)
            }
        }
        remapper.onWarningChanged = { [weak self] warning in
            DispatchQueue.main.async {
                self?.remapperWarning = warning
                self?.refreshUI(capsModeEnabled: self?.remapper.capsModeEnabled ?? false)
            }
        }
        windowSpecificInputMemory.onStatusChanged = { [weak self] status in
            self?.windowSpecificInputStatus = status
            self?.refreshUI(capsModeEnabled: self?.remapper.capsModeEnabled ?? false)
        }

        applyFeatureSettings(promptForPermission: false)
        if startsHidden {
            hideDockIcon()
        } else {
            showControls()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionRetryTimer?.invalidate()
        windowSpecificInputMemory.stop()
        remapper.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        retryFailedInstantCapsIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Mac Input Tweak"
    }

    private func installContextMenu() {
        toggleInstantCapsMenuItem.target = self
        toggleWindowInputMemoryMenuItem.target = self
        quitMenuItem.target = self
        statusContextMenu.addItem(toggleInstantCapsMenuItem)
        statusContextMenu.addItem(toggleWindowInputMemoryMenuItem)
        statusContextMenu.addItem(.separator())
        statusContextMenu.addItem(quitMenuItem)
    }

    private func installControlsWindow() {
        controlsWindowController = ControlsWindowController()
        controlsWindowController.onToggleInstantCaps = { [weak self] enabled in
            self?.setInstantCapsEnabled(enabled, promptForPermission: enabled)
        }
        controlsWindowController.onToggleWindowInputMemory = { [weak self] enabled in
            self?.setWindowInputMemoryEnabled(enabled, promptForPermission: enabled)
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
        UserDefaults.standard.set(enabled, forKey: Self.instantCapsPreferenceKey)
        applyInstantCapsSetting(promptForPermission: promptForPermission)
        if isWindowInputMemoryEnabled {
            windowSpecificInputMemory.setPaused(remapper.capsModeEnabled)
        }
        refreshUI(capsModeEnabled: remapper.capsModeEnabled)
    }

    private func setWindowInputMemoryEnabled(_ enabled: Bool, promptForPermission: Bool) {
        isWindowInputMemoryEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.windowInputMemoryPreferenceKey)
        applyWindowInputMemorySetting(promptForPermission: promptForPermission)
        refreshUI(capsModeEnabled: remapper.capsModeEnabled)
    }

    private func applyFeatureSettings(promptForPermission: Bool) {
        applyInstantCapsSetting(promptForPermission: promptForPermission)
        applyWindowInputMemorySetting(promptForPermission: promptForPermission)
        refreshUI(capsModeEnabled: remapper.capsModeEnabled)
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
                if let missingPermissionMessage = PermissionHelper.missingPermissionMessage() {
                    lastHookError = "\(missingPermissionMessage) \(PermissionHelper.diagnosticSummary()) Hook error: \(error.localizedDescription)"
                } else {
                    lastHookError = "Keyboard hook failed: \(error.localizedDescription)"
                }
            }
        } else {
            remapper.stop()
            remapperRunning = false
            lastHookError = nil
            remapperWarning = nil
        }
    }

    private func retryFailedInstantCapsIfNeeded() {
        guard isInstantCapsEnabled, !remapperRunning else {
            updatePermissionRetryTimer()
            return
        }

        applyInstantCapsSetting(promptForPermission: false)
        if isWindowInputMemoryEnabled {
            windowSpecificInputMemory.setPaused(remapper.capsModeEnabled)
        }
        refreshUI(capsModeEnabled: remapper.capsModeEnabled)
    }

    private func updatePermissionRetryTimer() {
        let shouldRetry = isInstantCapsEnabled && !remapperRunning
        if shouldRetry, permissionRetryTimer == nil {
            let timer = Timer(
                timeInterval: 1.0,
                target: self,
                selector: #selector(handlePermissionRetryTimer(_:)),
                userInfo: nil,
                repeats: true
            )
            permissionRetryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !shouldRetry {
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
        }
    }

    @objc private func handlePermissionRetryTimer(_ timer: Timer) {
        _ = timer
        retryFailedInstantCapsIfNeeded()
    }

    private func applyWindowInputMemorySetting(promptForPermission: Bool) {
        if isWindowInputMemoryEnabled {
            if promptForPermission {
                PermissionHelper.promptForAccessibilityPermission()
            }

            windowSpecificInputMemory.start()
            windowSpecificInputMemory.setPaused(remapper.capsModeEnabled)
        } else {
            windowSpecificInputMemory.stop()
            windowSpecificInputStatus = nil
        }
    }

    private func refreshUI(capsModeEnabled: Bool) {
        defer {
            updatePermissionRetryTimer()
        }

        controlsWindowController?.setFeatureStates(
            instantCapsEnabled: isInstantCapsEnabled,
            windowInputMemoryEnabled: isWindowInputMemoryEnabled
        )
        toggleInstantCapsMenuItem.title = isInstantCapsEnabled ? "Turn Off Instant Caps Lock" : "Turn On Instant Caps Lock"
        toggleWindowInputMemoryMenuItem.title = isWindowInputMemoryEnabled ? "Turn Off Window Input Memory" : "Turn On Window Input Memory"

        if !isInstantCapsEnabled && !isWindowInputMemoryEnabled {
            controlsWindowController?.setStatus(text: "Both tweaks are off. macOS input behavior is unchanged.", isError: false)
            setStatusBarIcon(mode: .disabled)
            return
        }

        if isInstantCapsEnabled && !remapperRunning {
            let errorText = lastHookError ?? "Instant Caps Lock keyboard hook unavailable."
            controlsWindowController?.setStatus(text: errorText, isError: true)
            setStatusBarIcon(mode: .error)
            return
        }

        var statusLines: [String] = []
        if isInstantCapsEnabled {
            let capsText = capsModeEnabled ? "Caps mode ON" : "Caps mode OFF"
            statusLines.append("Instant Caps Lock is active. Press Caps Lock to toggle immediately (\(capsText)).")
            if let remapperWarning {
                statusLines.append(remapperWarning)
            }
        } else {
            statusLines.append("Instant Caps Lock is off.")
        }

        if isWindowInputMemoryEnabled {
            statusLines.append(windowSpecificInputStatus ?? "Window-specific input memory is starting.")
        } else {
            statusLines.append("Window-specific input memory is off.")
        }

        controlsWindowController?.setStatus(text: statusLines.joined(separator: "\n"), isError: false)

        if isInstantCapsEnabled {
            if remapperWarning != nil {
                setStatusBarIcon(mode: .warning)
            } else {
                setStatusBarIcon(mode: capsModeEnabled ? .enabledCapsOn : .enabledCapsOff)
            }
        } else {
            setStatusBarIcon(mode: .windowMemoryOnly)
        }
    }

    private enum StatusIconMode {
        case disabled
        case enabledCapsOff
        case enabledCapsOn
        case windowMemoryOnly
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
        case .windowMemoryOnly:
            symbolName = "keyboard"
        case .warning:
            symbolName = "exclamationmark.triangle"
        case .error:
            symbolName = "exclamationmark.triangle"
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        if
            let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Mac Input Tweak"),
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

    @objc private func toggleInstantCapsFromMenu() {
        setInstantCapsEnabled(!isInstantCapsEnabled, promptForPermission: !isInstantCapsEnabled)
    }

    @objc private func toggleWindowInputMemoryFromMenu() {
        setWindowInputMemoryEnabled(!isWindowInputMemoryEnabled, promptForPermission: !isWindowInputMemoryEnabled)
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
