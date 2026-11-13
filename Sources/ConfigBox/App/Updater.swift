import AppKit
import CryptoKit
import Security

/// Looks for a newer ConfigBox on GitHub Releases and installs it in place of the running copy.
///
/// An update is only installed when the downloaded zip matches the SHA-256 GitHub reports for the asset and
/// the app inside is signed so that it satisfies the running app's designated requirement (same identifier
/// and same signing certificate). The latter also keeps the TCC grants, which are tied to that requirement.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repo = "hayato-ohya/configbox"

    struct Release: Equatable {
        let version: String
        let notes: String
        let pageURL: URL
        let assetURL: URL
        let assetName: String
        let sha256: String
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The newest release seen that is newer than the running app; kept while installing and after a failure.
    @Published private(set) var available: Release?
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: lastCheckKey) as? Date

    var isBusy: Bool { [.checking, .downloading, .installing].contains(state) }

    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 3600
    private var timer: Timer?

    // MARK: Automatic checks

    /// Turns the daily background check on or off. A check is due right away (after a short delay, so it
    /// does not compete with launch) when the last one is more than a day old.
    func setAutomatic(_ on: Bool) {
        guard on != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard timer != nil, !isBusy else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    // MARK: Checking

    /// `thenInstall` installs a newer release right away (scripting aid: `--install-update`).
    func check(userInitiated: Bool = true, thenInstall: Bool = false) {
        guard !isBusy else { return }
        let previous = state
        state = .checking
        Task {
            do {
                let release = try await Self.fetchLatest()
                lastChecked = Date()
                UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckKey)
                if Self.isNewer(release.version, than: AppVersion.short) {
                    if available?.version != release.version { Log.info("update: \(release.version) is available") }
                    available = release
                    state = .available
                    if thenInstall { install() }
                } else {
                    available = nil
                    state = .upToDate
                }
            } catch {
                Log.error("update check failed: \(error.localizedDescription)")
                // A failed background check should not leave an error in the About section.
                state = userInitiated ? .failed(error.localizedDescription) : (available != nil ? .available : previous)
            }
        }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    nonisolated private static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    nonisolated private static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ConfigBox/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError(L("GitHub returned an unexpected response (%@).", "\((response as? HTTPURLResponse)?.statusCode ?? 0)"))
        }
        let gh = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = gh.tag_name.hasPrefix("v") ? String(gh.tag_name.dropFirst()) : gh.tag_name
        guard let asset = gh.assets.first(where: { $0.name.hasPrefix("ConfigBox-") && $0.name.hasSuffix("-\(arch).zip") }) else {
            throw UpdateError(L("Release %@ has no download for this Mac.", version))
        }
        guard let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw UpdateError(L("Release %@ does not list a SHA-256 checksum for its download.", version))
        }
        return Release(version: version, notes: gh.body ?? "", pageURL: gh.html_url, assetURL: asset.browser_download_url,
                       assetName: asset.name, sha256: String(digest.dropFirst("sha256:".count)).lowercased())
    }

    /// Compares dotted version numbers ("0.10.0" > "0.9.3"); a missing part counts as 0, a suffix after "-" is ignored.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let core = v.drop { $0 == "v" }.split(separator: "-", maxSplits: 1).first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    /// Where an update would be installed, or why it cannot be.
    static var installProblem: String? {
        if isAdHocSigned { return adHocMessage }
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") {
            return L("ConfigBox is running from a temporary location. Move it to the Applications folder first.")
        }
        if !FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) {
            return L("You do not have permission to replace %@.", path)
        }
        return nil
    }

    func install() {
        guard let release = available, !isBusy else { return }
        if let problem = Self.installProblem { state = .failed(problem); return }
        state = .downloading
        let target = Bundle.main.bundleURL
        Task {
            do {
                let zip = try await Self.download(release)
                state = .installing
                try await Task.detached { try Self.replace(target, withAppIn: zip, release: release) }.value
                Log.info("update: installed \(release.version) at \(target.path); relaunching")
                AppLanguage.relaunch()
            } catch {
                Log.error("update to \(release.version) failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated private static func download(_ release: Release) async throws -> URL {
        var req = URLRequest(url: release.assetURL)
        req.setValue("ConfigBox/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        let (tmp, response) = try await URLSession.shared.download(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw UpdateError(L("The download failed (%@).", "\((response as? HTTPURLResponse)?.statusCode ?? 0)"))
        }
        // URLSession deletes its temp file when this returns, so keep it under our own name.
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigBox-update-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: tmp, to: zip)
        return zip
    }

    nonisolated private static func replace(_ target: URL, withAppIn zip: URL, release: Release) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: zip) }

        let data = try Data(contentsOf: zip)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == release.sha256 else {
            throw UpdateError(L("The downloaded file does not match its published checksum."))
        }

        // Unpack next to the installed app (same volume) so the final swap is a rename.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: work) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let app = work.appendingPathComponent("ConfigBox.app")
        guard fm.fileExists(atPath: app.path), let info = Bundle(url: app)?.infoDictionary else {
            throw UpdateError(L("The download does not contain ConfigBox.app."))
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError(L("The downloaded app is not ConfigBox."))
        }
        guard info["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError(L("The downloaded app is not version %@.", release.version))
        }
        try verifySignature(of: app)
        // Downloads made by URLSession are not quarantined, but an unexpected flag would make Gatekeeper
        // reject the self-signed app on relaunch.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

        _ = try fm.replaceItemAt(target, withItemAt: app)
    }

    /// Without a certificate the designated requirement is this exact build's hash, which no other build can meet.
    nonisolated static let isAdHocSigned: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var signing: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess
        else { return true }
        let certs = (signing as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any]
        return certs?.isEmpty ?? true
    }()

    nonisolated private static var adHocMessage: String {
        L("This copy of ConfigBox is ad-hoc signed, so an update cannot be verified. Download it from the release page instead.")
    }

    /// The new app must satisfy the running app's designated requirement: same identifier, same certificate.
    nonisolated static func verifySignature(of app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic,
              SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError(L("Could not read the running app's code signature."))
        }
        guard !isAdHocSigned else { throw UpdateError(adHocMessage) }

        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError(L("The downloaded app's code signature could not be read."))
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(newCode, flags, requirement)
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            throw UpdateError(L("The downloaded app is not signed by the same developer as this copy (%@).", reason))
        }
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError(L("%@ failed with status %@.", (tool as NSString).lastPathComponent, "\(p.terminationStatus)"))
        }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
