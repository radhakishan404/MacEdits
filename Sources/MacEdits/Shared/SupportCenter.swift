import AppKit
import Foundation

struct CrashReportContext: Identifiable, Hashable {
    let id = UUID()
    let fileURL: URL
    let modifiedAt: Date
    let excerpt: String

    var fileName: String {
        fileURL.lastPathComponent
    }
}

enum SupportCenter {
    static let supportEmail = "support@macedits.app"
    static let bugReportRepository = "https://github.com/radhakishan404/MacEdits"

    private static let crashReportFolderPath = "Library/Logs/DiagnosticReports"
    private static let lastHandledCrashTimestampKey = "support.lastHandledCrashReportTimestamp"

    static func detectLatestUnreportedCrash(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        homeDirectoryOverride: URL? = nil
    ) -> CrashReportContext? {
        let homeDirectory = homeDirectoryOverride ?? fileManager.homeDirectoryForCurrentUser
        let crashFolder = homeDirectory
            .appendingPathComponent(crashReportFolderPath, isDirectory: true)
        guard let reportFiles = try? fileManager.contentsOfDirectory(
            at: crashFolder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let lastHandledTimestamp = defaults.double(forKey: lastHandledCrashTimestampKey)
        let sorted = reportFiles
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "crash" || ext == "ips"
            }
            .compactMap { url -> (url: URL, modifiedAt: Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modifiedAt = values.contentModificationDate
                else {
                    return nil
                }
                return (url, modifiedAt)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }

        for item in sorted where item.modifiedAt.timeIntervalSince1970 > lastHandledTimestamp {
            guard let content = try? String(contentsOf: item.url) else { continue }
            guard looksLikeMacEditsCrash(fileURL: item.url, content: content) else { continue }
            let excerpt = crashExcerpt(from: content)
            return CrashReportContext(fileURL: item.url, modifiedAt: item.modifiedAt, excerpt: excerpt)
        }

        return nil
    }

    static func markCrashAsHandled(_ crash: CrashReportContext, defaults: UserDefaults = .standard) {
        defaults.set(crash.modifiedAt.timeIntervalSince1970, forKey: lastHandledCrashTimestampKey)
    }

    static func openSupportEmail(subject: String, body: String) {
        guard let url = supportEmailURL(subject: subject, body: body) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openBugReportURL(title: String, body: String, labels: [String] = ["bug"]) {
        guard let url = githubIssueURL(title: title, body: body, labels: labels) else { return }
        NSWorkspace.shared.open(url)
    }

    static func supportEmailURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    static func githubIssueURL(title: String, body: String, labels: [String]) -> URL? {
        guard var components = URLComponents(string: "\(bugReportRepository)/issues/new") else {
            return nil
        }
        let labelString = labels.joined(separator: ",")
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "labels", value: labelString),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }

    static func crashIssueTitle(_ crash: CrashReportContext) -> String {
        "[Crash] \(crash.fileName)"
    }

    static func crashIssueBody(_ crash: CrashReportContext) -> String {
        """
        ## Crash Summary
        - Crash log file: \(crash.fileName)
        - Crash timestamp: \(iso8601Date(crash.modifiedAt))
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - App version: \(appVersionDescription)

        ## What I was doing
        <!-- Please describe the steps before the crash -->

        ## Expected behavior
        <!-- What should have happened -->

        ## Actual behavior
        App crashed.

        ## Crash excerpt
        ```
        \(crash.excerpt)
        ```
        """
    }

    static var genericBugIssueBody: String {
        """
        ## Summary
        <!-- Short bug description -->

        ## Steps to reproduce
        1.
        2.
        3.

        ## Expected behavior
        <!-- What should happen -->

        ## Actual behavior
        <!-- What actually happens -->

        ## Environment
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - App version: \(appVersionDescription)
        """
    }

    static var genericSupportEmailBody: String {
        """
        Hi MacEdits team,

        I need help with:
        - 

        Environment:
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - App version: \(appVersionDescription)
        """
    }

    static func supportEmailBody(for crash: CrashReportContext) -> String {
        """
        Hi MacEdits team,

        The app crashed. Sharing details below.

        Crash file: \(crash.fileName)
        Crash timestamp: \(iso8601Date(crash.modifiedAt))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        App version: \(appVersionDescription)

        Crash excerpt:
        \(crash.excerpt)
        """
    }

    private static var appVersionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    private static func iso8601Date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func looksLikeMacEditsCrash(fileURL: URL, content: String) -> Bool {
        let name = fileURL.lastPathComponent.lowercased()
        if name.contains("macedits") {
            return true
        }
        let lower = content.lowercased()
        return lower.contains("process:             macedits")
            || lower.contains("identifier:          com.macedits.dev")
            || lower.contains("identifier:          com.macedits")
    }

    private static func crashExcerpt(from content: String, maxLength: Int = 1800) -> String {
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(60)
            .map(String.init)
            .joined(separator: "\n")

        if lines.count <= maxLength {
            return lines
        }
        let endIndex = lines.index(lines.startIndex, offsetBy: maxLength)
        return String(lines[..<endIndex]) + "\n…"
    }
}
