import AppKit

// Update checking against GitHub Releases.
//
// No Sparkle and no appcast: the app is not notarised, so the whole framework would be more moving
// parts than value. This uses the public Releases API, compares semantic versions, and installs by
// replacing the bundle and relaunching.

enum Updater {

    static let repository = "Wizard242008/pulsar"

    struct Release {
        let version: String        // normalised, e.g. "2.1.0"
        let tag: String            // as published, e.g. "v2.1.0"
        let notes: String
        let pageURL: URL?
        let dmgURL: URL?
    }

    enum Result {
        case upToDate(current: String)
        case available(Release)
        case failed(String)
    }

    // MARK: - version comparison

    /// "v2.1" -> [2, 1, 0]. Missing components count as zero so 2.0 and 2.0.0 compare equal.
    static func components(_ raw: String) -> [Int] {
        let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        var parts = core.split(separator: ".").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        return parts
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for index in 0..<max(a.count, b.count) {
            let lhs = index < a.count ? a[index] : 0
            let rhs = index < b.count ? b[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    // MARK: - checking

    static func check(completion: @escaping (Result) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            completion(.failed("Bad URL"))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pulsar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            let finish: (Result) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error {
                finish(.failed(error.localizedDescription))
                return
            }
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String else {
                finish(.failed("Unexpected response from GitHub"))
                return
            }

            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isNewer(version, than: currentVersion) else {
                finish(.upToDate(current: currentVersion))
                return
            }

            let assets = object["assets"] as? [[String: Any]] ?? []
            let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            let release = Release(
                version: version,
                tag: tag,
                notes: (object["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                pageURL: (object["html_url"] as? String).flatMap(URL.init(string:)),
                dmgURL: (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:))
            )
            finish(.available(release))
        }.resume()
    }

    // MARK: - installing

    /// Download the release DMG, copy the app out of it, swap it into /Applications and relaunch.
    ///
    /// The swap runs in a detached shell script: this process is the old bundle, so it has to be
    /// able to finish exiting before its own replacement is put in place.
    static func install(_ release: Release, completion: @escaping (String?) -> Void) {
        guard let dmgURL = release.dmgURL else {
            completion("This release has no .dmg attached.")
            return
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pulsar-update", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("Pulsar-\(release.version).dmg")

        URLSession.shared.downloadTask(with: dmgURL) { location, _, error in
            guard let location, error == nil else {
                DispatchQueue.main.async { completion(error?.localizedDescription ?? "Download failed") }
                return
            }
            try? FileManager.default.removeItem(at: dmg)
            guard (try? FileManager.default.moveItem(at: location, to: dmg)) != nil else {
                DispatchQueue.main.async { completion("Could not save the download") }
                return
            }

            let mountPoint = work.appendingPathComponent("mnt")
            try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

            let attach = Process()
            attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            attach.arguments = ["attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mountPoint.path]
            do { try attach.run(); attach.waitUntilExit() } catch {
                DispatchQueue.main.async { completion("Could not mount the disk image") }
                return
            }

            let staged = work.appendingPathComponent("Pulsar.app")
            try? FileManager.default.removeItem(at: staged)
            let copy = Process()
            copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            copy.arguments = [mountPoint.appendingPathComponent("Pulsar.app").path, staged.path]
            do { try copy.run(); copy.waitUntilExit() } catch {
                DispatchQueue.main.async { completion("Could not copy the new app") }
                return
            }

            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint.path, "-quiet", "-force"]
            try? detach.run()

            guard FileManager.default.fileExists(atPath: staged.path) else {
                DispatchQueue.main.async { completion("The disk image did not contain Pulsar.app") }
                return
            }

            let script = work.appendingPathComponent("swap.sh")
            let body = """
            #!/bin/bash
            sleep 0.4
            rm -rf /Applications/Pulsar.app
            /usr/bin/ditto "\(staged.path)" /Applications/Pulsar.app
            /usr/bin/xattr -dr com.apple.quarantine /Applications/Pulsar.app 2>/dev/null
            /usr/bin/open /Applications/Pulsar.app
            """
            try? body.write(to: script, atomically: true, encoding: .utf8)

            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/bash")
            swap.arguments = [script.path]
            do {
                try swap.run()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion("Could not start the installer") }
            }
        }.resume()
    }
}
