import AppKit

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()
    let appDelegate = AppDelegate()
}

autoreleasepool {
    let app = NSApplication.shared
    _ = AppRuntime.shared
    app.delegate = AppRuntime.shared.appDelegate
    app.run()
}
