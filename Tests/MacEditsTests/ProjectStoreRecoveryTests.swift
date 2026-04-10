import XCTest
@testable import MacEdits

final class ProjectStoreRecoveryTests: XCTestCase {
    func testAutosaveRecoveryMessageWhenAutosaveIsNewer() throws {
        let store = ProjectStore()
        let fixture = try makeProjectFixture(primaryExists: true)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }

        let now = Date()
        let older = now.addingTimeInterval(-120)
        let newer = now.addingTimeInterval(-10)
        try setModificationDate(older, for: fixture.primaryURL)
        try setModificationDate(newer, for: fixture.autosaveURL)

        let message = store.autosaveRecoveryMessage(for: fixture.projectURL)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Recovered newer autosave") == true)
    }

    func testAutosaveRecoveryMessageNilWhenPrimaryIsNewer() throws {
        let store = ProjectStore()
        let fixture = try makeProjectFixture(primaryExists: true)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }

        let now = Date()
        let newerPrimary = now.addingTimeInterval(-5)
        let olderAutosave = now.addingTimeInterval(-180)
        try setModificationDate(newerPrimary, for: fixture.primaryURL)
        try setModificationDate(olderAutosave, for: fixture.autosaveURL)

        let message = store.autosaveRecoveryMessage(for: fixture.projectURL)
        XCTAssertNil(message)
    }

    func testAutosaveRecoveryMessageWhenPrimaryIsMissing() throws {
        let store = ProjectStore()
        let fixture = try makeProjectFixture(primaryExists: false)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }

        let message = store.autosaveRecoveryMessage(for: fixture.projectURL)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Recovered from autosave snapshot") == true)
    }

    func testRecoveryInfoExistsWhenAutosaveIsNewer() throws {
        let store = ProjectStore()
        let fixture = try makeProjectFixture(primaryExists: true)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }

        let now = Date()
        try setModificationDate(now.addingTimeInterval(-180), for: fixture.primaryURL)
        try setModificationDate(now.addingTimeInterval(-10), for: fixture.autosaveURL)

        let info = store.recoveryInfo(for: fixture.projectURL)
        XCTAssertNotNil(info)
        XCTAssertTrue(info?.message.contains("A newer autosave exists.") == true)
    }

    func testRecoveryInfoNilWhenPrimaryMissing() throws {
        let store = ProjectStore()
        let fixture = try makeProjectFixture(primaryExists: false)
        defer { try? FileManager.default.removeItem(at: fixture.projectURL) }

        let info = store.recoveryInfo(for: fixture.projectURL)
        XCTAssertNil(info)
    }

    private func makeProjectFixture(primaryExists: Bool) throws -> (projectURL: URL, primaryURL: URL, autosaveURL: URL) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("macedits-recovery-\(UUID().uuidString)", isDirectory: true)
        let projectURL = root.appendingPathComponent("RecoveryFixture.macedits", isDirectory: true)
        let autosaveDirectory = projectURL.appendingPathComponent("autosave", isDirectory: true)
        let primaryURL = projectURL.appendingPathComponent("project.json")
        let autosaveURL = autosaveDirectory.appendingPathComponent("snapshot-\(Int(Date().timeIntervalSince1970 * 1000)).json")

        try fileManager.createDirectory(at: autosaveDirectory, withIntermediateDirectories: true)
        if primaryExists {
            try Data("{}".utf8).write(to: primaryURL, options: .atomic)
        }
        try Data("{}".utf8).write(to: autosaveURL, options: .atomic)
        return (projectURL, primaryURL, autosaveURL)
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path())
    }
}
