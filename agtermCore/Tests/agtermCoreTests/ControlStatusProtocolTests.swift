import Foundation
import Testing
@testable import agtermCore

/// Wire format for the `session.status --icon` argument and its `statusIcon` read-back. Split out of
/// `ControlProtocolTests` for the swiftlint file limit.
struct ControlStatusProtocolTests {
    @Test func sessionStatusRoundTripsWithIconAndOmitsItWhenNil() throws {
        let request = ControlRequest(cmd: .sessionStatus, target: "9f3c",
                                     args: ControlArgs(status: "active", icon: "/icons/agent.png"))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
        let plain = ControlRequest(cmd: .sessionStatus, target: "9f3c", args: ControlArgs(status: "active"))
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("icon"), "a nil icon must be omitted from the JSON; got \(json)")
    }

    @Test func treeSessionNodeRoundTripsWithStatusIconAndOmitsItWhenNil() throws {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false,
                                         backedByZmx: nil, status: "active", statusIcon: "/icons/agent.png")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)
        let plain = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false, status: "active")
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("statusIcon"), "a nil statusIcon must be omitted; got \(json)")
    }
}
