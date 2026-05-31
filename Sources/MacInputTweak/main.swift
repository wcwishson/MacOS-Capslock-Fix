import AppKit
import ApplicationServices
import IOKit.hid

nonisolated(unsafe) private let diagnosticEventTapCallback: CGEventTapCallBack = { _, _, event, _ in
    Unmanaged.passUnretained(event)
}

private func runPermissionDiagnosticsIfRequested() {
    guard ProcessInfo.processInfo.arguments.contains("--diagnose-permissions") else {
        return
    }

    var lines: [String] = [
        "PID: \(getpid())",
        "Executable: \(Bundle.main.executablePath ?? "unknown")",
        "Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")",
        "Args: \(ProcessInfo.processInfo.arguments.joined(separator: " "))",
        PermissionHelper.diagnosticSummary(),
    ]

    let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue),
        callback: diagnosticEventTapCallback,
        userInfo: nil
    )
    lines.append("Event tap: \(tap == nil ? "failed" : "created")")

    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Int] = [
        kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop),
        kIOHIDDeviceUsageKey: Int(kHIDUsage_GD_Keyboard),
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    lines.append("IOHID manager: \(openResult == kIOReturnSuccess ? "opened" : "failed \(openResult)")")
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))

    let output = lines.joined(separator: "\n")
    print(output)

    if
        let outputIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--diagnose-permissions-output"),
        ProcessInfo.processInfo.arguments.indices.contains(outputIndex + 1)
    {
        let outputPath = ProcessInfo.processInfo.arguments[outputIndex + 1]
        try? output.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    exit(tap == nil ? 1 : 0)
}

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()
    let appDelegate = AppDelegate()
}

autoreleasepool {
    runPermissionDiagnosticsIfRequested()

    let app = NSApplication.shared
    _ = AppRuntime.shared
    app.delegate = AppRuntime.shared.appDelegate
    app.run()
}
