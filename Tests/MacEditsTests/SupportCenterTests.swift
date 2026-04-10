import Foundation
import XCTest
@testable import MacEdits

final class SupportCenterTests: XCTestCase {
    func testDetectLatestUnreportedCrashAndMarkHandled() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let crashDir = tempRoot.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        try fileManager.createDirectory(at: crashDir, withIntermediateDirectories: true)

        let crashFile = crashDir.appendingPathComponent("MacEdits-test.crash")
        let crashContent = """
        Process:             MacEdits [12345]
        Identifier:          com.macedits.dev
        Exception Type:      EXC_BREAKPOINT (SIGTRAP)
        """
        try crashContent.write(to: crashFile, atomically: true, encoding: .utf8)
        let crashDate = Date().addingTimeInterval(-5)
        try fileManager.setAttributes([.modificationDate: crashDate], ofItemAtPath: crashFile.path)

        let defaultsSuite = "SupportCenterTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            XCTFail("Could not create isolated user defaults")
            return
        }
        defaults.removePersistentDomain(forName: defaultsSuite)

        let detected = SupportCenter.detectLatestUnreportedCrash(
            fileManager: fileManager,
            defaults: defaults,
            homeDirectoryOverride: tempRoot
        )
        XCTAssertEqual(detected?.fileName, "MacEdits-test.crash")

        if let detected {
            SupportCenter.markCrashAsHandled(detected, defaults: defaults)
        } else {
            XCTFail("Expected crash report to be detected")
        }

        let secondDetection = SupportCenter.detectLatestUnreportedCrash(
            fileManager: fileManager,
            defaults: defaults,
            homeDirectoryOverride: tempRoot
        )
        XCTAssertNil(secondDetection)

        try? fileManager.removeItem(at: tempRoot)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    func testSupportEmailURLIncludesSubjectAndBody() {
        let url = SupportCenter.supportEmailURL(
            subject: "Need help",
            body: "App crashed during export."
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("mailto:support@macedits.app") == true)
        XCTAssertTrue(url?.absoluteString.contains("subject=Need%20help") == true)
    }

    func testGithubIssueURLIncludesLabels() {
        let url = SupportCenter.githubIssueURL(
            title: "[Crash] Sample",
            body: "Stack trace",
            labels: ["bug", "crash"]
        )
        XCTAssertNotNil(url)
        guard let components = URLComponents(url: url!, resolvingAgainstBaseURL: false) else {
            XCTFail("Could not parse URL components")
            return
        }
        let labels = components.queryItems?.first(where: { $0.name == "labels" })?.value
        XCTAssertEqual(labels, "bug,crash")
    }
}
