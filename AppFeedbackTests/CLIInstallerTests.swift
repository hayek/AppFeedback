import XCTest
@testable import AppFeedback

#if os(macOS)
final class CLIInstallerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appending(path: "installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBinary(named name: String = "AppFeedback") throws -> URL {
        let url = root.appending(path: name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        return url
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - CLI

    func testInstallsIntoTheFirstWritableCandidate() throws {
        let preferred = root.appending(path: "usr-local-bin")   // deliberately absent
        let fallback = try makeDirectory("dot-local-bin")

        let installed = try CLIInstaller.installCLI(candidates: [preferred, fallback],
                                                    binary: try makeBinary())
        XCTAssertEqual(installed.deletingLastPathComponent().lastPathComponent, "dot-local-bin")
        XCTAssertEqual(installed.lastPathComponent, CLIBranding.commandName)
    }

    /// A copy would lose the provisioning profile and with it keychain access.
    func testInstallCreatesASymlinkNotACopy() throws {
        let directory = try makeDirectory("bin")
        let binary = try makeBinary()
        let installed = try CLIInstaller.installCLI(candidates: [directory], binary: binary)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installed.path),
                       binary.path, "must symlink, never copy")
    }

    func testInstallIsIdempotentAndRepointsAnExistingLink() throws {
        let directory = try makeDirectory("bin")
        _ = try CLIInstaller.installCLI(candidates: [directory], binary: try makeBinary(named: "Old"))
        let installed = try CLIInstaller.installCLI(candidates: [directory],
                                                    binary: try makeBinary(named: "New"))
        XCTAssertTrue(try FileManager.default.destinationOfSymbolicLink(atPath: installed.path)
            .hasSuffix("New"))
    }

    func testStatusReportsNotInstalledInstalledAndBroken() throws {
        let directory = try makeDirectory("bin")
        guard case .notInstalled = CLIInstaller.cliStatus(searchPaths: [directory]) else {
            return XCTFail("expected .notInstalled")
        }

        let binary = try makeBinary()
        let installed = try CLIInstaller.installCLI(candidates: [directory], binary: binary)
        guard case .installed(let url) = CLIInstaller.cliStatus(searchPaths: [directory]) else {
            return XCTFail("expected .installed")
        }
        XCTAssertEqual(url, installed)

        try FileManager.default.removeItem(at: binary)      // dangling link
        guard case .brokenLink = CLIInstaller.cliStatus(searchPaths: [directory]) else {
            return XCTFail("expected .brokenLink")
        }
    }

    func testInstallFailsCleanlyWhenNoCandidateIsWritable() throws {
        XCTAssertThrowsError(try CLIInstaller.installCLI(
            candidates: [URL(filePath: "/System/definitely-not-writable")],
            binary: try makeBinary()))
    }

    func testStatusSkipsAMissingCandidateAndFindsALaterOne() throws {
        let missing = root.appending(path: "nope")
        let directory = try makeDirectory("bin")
        _ = try CLIInstaller.installCLI(candidates: [directory], binary: try makeBinary())
        guard case .installed = CLIInstaller.cliStatus(searchPaths: [missing, directory]) else {
            return XCTFail("expected .installed from the second candidate")
        }
    }

    // MARK: - Skill

    func testInstallSkillSymlinksTheBundledFolder() throws {
        let source = try makeDirectory("Skill/appfeedback")
        try Data("---\nname: appfeedback\n---\n".utf8).write(to: source.appending(path: "SKILL.md"))
        let destination = root.appending(path: "home/.claude/skills/appfeedback")

        let installed = try CLIInstaller.installSkill(source: source, destination: destination)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installed.path),
                       source.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installed.appending(path: "SKILL.md").path),
            "the SKILL.md must be reachable through the link")
    }

    func testInstallSkillThrowsWhenTheBundledFolderIsMissing() {
        XCTAssertThrowsError(try CLIInstaller.installSkill(
            source: root.appending(path: "absent"),
            destination: root.appending(path: "dest")))
    }

    func testSkillDestinationIsTheClaudeSkillsFolder() {
        XCTAssertTrue(CLIInstaller.skillDestinationURL.path.hasSuffix(".claude/skills/appfeedback"))
    }

    /// Exec'ing through the installed symlink makes `Bundle.main` point at the symlink's
    /// directory, not the .app — which is why version read as "?" and the skill folder
    /// couldn't be found. The bundle must be resolved from argv[0] instead.
    func testAppBundleResolvesToARealBundle() {
        let bundle = CLIBranding.appBundle
        XCTAssertNotNil(bundle.bundleURL)
        // In the test host this is the app bundle itself, so it must carry an Info.plist.
        XCTAssertNotNil(bundle.infoDictionary?["CFBundleIdentifier"])
    }

    /// Opt-in: exercises the real install paths against the real home directory, which is what
    /// the Settings buttons do. Off by default so a normal test run never writes there.
    /// Enable with `APPFEEDBACK_LIVE_INSTALL=1`.
    func testLiveInstallIntoTheRealDestinations() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPFEEDBACK_LIVE_INSTALL"] == "1",
                          "set APPFEEDBACK_LIVE_INSTALL=1 to run the real install")

        let cli = try CLIInstaller.installCLI()
        print("installed CLI at \(cli.path) -> "
              + (try FileManager.default.destinationOfSymbolicLink(atPath: cli.path)))
        guard case .installed = CLIInstaller.cliStatus() else {
            return XCTFail("cliStatus should report installed")
        }

        let skill = try CLIInstaller.installSkill()
        print("installed skill at \(skill.path) -> "
              + (try FileManager.default.destinationOfSymbolicLink(atPath: skill.path)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skill.appending(path: "SKILL.md").path),
                      "SKILL.md must be reachable through the installed link")
        guard case .installed = CLIInstaller.skillStatus() else {
            return XCTFail("skillStatus should report installed")
        }
    }
}
#endif
