import AppKit

/// The running app's version as shown to the user, e.g. “0.3.3 (7)”.
enum AppVersion {
    static let display: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }()
}

/// Looks up a UI string that is held in a `String`. SwiftUI only localizes literals passed directly to
/// its views, so enum titles, helper parameters and AppKit menus go through this.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// The language the app runs in, kept in its own `AppleLanguages` default (the same value that
/// System Settings › Language & Region › Applications writes). It is read once at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ja
    var id: String { rawValue }

    private static let key = "AppleLanguages"
    /// What the running process started with, to tell whether a relaunch is still needed.
    static let atLaunch = current

    static var current: AppLanguage {
        get {
            let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
            return (domain?[key] as? [String])?.first.flatMap { AppLanguage(rawValue: $0) } ?? .system
        }
        set {
            if newValue == .system { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set([newValue.rawValue], forKey: key) }
        }
    }

    /// Starts a new instance once this one has exited, returning to the Settings section.
    static func relaunch() {
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\" --args --section settings"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, Bundle.main.bundlePath]
        guard (try? p.run()) != nil else { return Log.error("Could not schedule a relaunch") }
        NSApp.terminate(nil)
    }
}
