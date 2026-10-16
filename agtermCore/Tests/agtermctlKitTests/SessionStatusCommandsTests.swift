import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

/// `session status --icon` parsing. Split out of `CommandsTests` for the swiftlint file limit.
struct SessionStatusCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Agtermctl.parseAsRoot(argv)
            return nil
        } catch {
            return Agtermctl.message(for: error)
        }
    }

    @Test func sessionStatusSendsAnAbsoluteIconUntouched() throws {
        #expect(try request(["session", "status", "active", "--icon", "/icons/agent.png"]).args?.icon == "/icons/agent.png")
        #expect(try request(["session", "status", "active"]).args?.icon == nil)
    }

    @Test func sessionStatusSendsNoneUntouched() throws {
        #expect(try request(["session", "status", "idle", "--icon", "none"]).args?.icon == "none")
    }

    @Test func sessionStatusResolvesARelativeIconAgainstTheCallersDirectory() throws {
        let req = try request(["session", "status", "active", "--icon", "icons/../agent.png"])
        let cwd = FileManager.default.currentDirectoryPath
        #expect(req.args?.icon == URL(fileURLWithPath: cwd).appendingPathComponent("agent.png").standardizedFileURL.path)
    }

    @Test func sessionStatusRejectsAnUnsupportedIcon() {
        #expect(validationMessage(["session", "status", "active", "--icon", "/icons/agent.gif"])
            == "icon must be none or a .png, .jpg, .jpeg, .pdf or .svg path without control characters")
    }
}
