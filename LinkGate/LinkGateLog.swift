import OSLog

enum LinkGateLog {
    private static let subsystem = "com.nickghardwick.LinkGate"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let routing = Logger(subsystem: subsystem, category: "routing")
    static let browser = Logger(subsystem: subsystem, category: "browser")
    static let defaultBrowser = Logger(subsystem: subsystem, category: "default-browser")
    static let launchAtLogin = Logger(subsystem: subsystem, category: "launch-at-login")
    static let updater = Logger(subsystem: subsystem, category: "updater")
}
