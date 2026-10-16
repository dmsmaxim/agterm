import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the sidebar row's name tooltip, which appears only while the label is too narrow to
/// show the whole name, and for the leading icon each kind of row draws.
@MainActor
final class SidebarRowViewsTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var scroll: NSScrollView!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-row-views-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            window?.orderOut(nil)
            window = nil
            scroll = nil
            outline = nil
            coordinator = nil
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testATruncatedNameGetsTheFullNameAsItsTooltip() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)

        let name = "PROJ-123 enforce the storage quota on the plan endpoint before the billing cutover"
        store.renameSession(session.id, to: name)
        coordinator.reconcile()

        let field = try renderedNameField(forSession: session.id)
        XCTAssertEqual(field.toolTip, name,
                       "a name the row cannot show needs a hover reveal; the label truncates with no other way to read it")
    }

    func testANameThatFitsGetsNoTooltip() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)

        store.renameSession(session.id, to: "api")
        coordinator.reconcile()

        let field = try renderedNameField(forSession: session.id)
        XCTAssertNil(field.toolTip, "a fully visible name needs no tooltip; repeating it on hover is noise")
    }

    func testATitleTickRefreshesTheTooltipOnTheLiveCell() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)
        let cell = try renderedCell(forSession: session.id)
        let long = "PROJ-123 enforce the storage quota on the plan endpoint before the billing cutover"

        for (title, expected) in [("api", nil), (long, long), ("api", nil)] {
            session.oscTitle = title
            coordinator.reconcile()
            cell.layoutSubtreeIfNeeded()
            XCTAssertTrue(try renderedCell(forSession: session.id) === cell, "a title tick must keep the cell")
            XCTAssertEqual(cell.textField?.stringValue, title)
            XCTAssertEqual(cell.textField?.toolTip, expected, "the relabel must schedule the layout pass that owns the tooltip")
        }
    }

    func testWideningTheRowClearsAToolTipItNoLongerNeeds() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)

        store.renameSession(session.id, to: "PROJ-123 enforce the storage quota on the plan endpoint")
        coordinator.reconcile()
        let narrow = try renderedNameField(forSession: session.id)
        XCTAssertNotNil(narrow.toolTip, "the narrow sidebar should truncate this name")
        let narrowWidth = narrow.bounds.width

        setSidebarWidth(CGFloat(AppStore.sidebarWidthMax))

        let field = try renderedNameField(forSession: session.id)
        XCTAssertGreaterThan(field.bounds.width, narrowWidth,
                             "the row must widen here, or the tooltip assertion below proves nothing")
        XCTAssertNil(field.toolTip, "dragging the divider wider must re-evaluate, or a stale tooltip lingers")
    }

    func testARemoteSessionRowGetsItsOwnIcon() throws {
        let store = try XCTUnwrap(library.activeStore)
        let local = try XCTUnwrap(store.activeSession)
        let remote = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a", remoteHost: "buildbox"))
        buildSidebar(for: store)

        let remoteIcon = try renderedIcon(forSession: remote.id)
        let localIcon = try renderedIcon(forSession: local.id)

        XCTAssertEqual(remoteIcon, coordinator.remoteSessionIcon)
        XCTAssertNotEqual(remoteIcon, localIcon, "a teleported row must be tellable from a local one at a glance")
    }

    func testARemoteRowStillShowsAHiddenSplit() throws {
        let store = try XCTUnwrap(library.activeStore)
        let remote = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a", remoteHost: "buildbox"))
        store.toggleSplit(remote.id)
        store.toggleSplit(remote.id)
        buildSidebar(for: store)

        XCTAssertTrue(remote.hasSplit, "the pane is alive but hidden; the row is the only place this shows")
        XCTAssertEqual(try renderedIcon(forSession: remote.id), coordinator.remoteSplitSessionIcon)
    }

    func testAFlaggedRemoteRowKeepsTheUnsplitWeight() throws {
        let store = try XCTUnwrap(library.activeStore)
        let remote = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/a", remoteHost: "buildbox"))
        remote.flagged = true
        buildSidebar(for: store)

        XCTAssertEqual(try renderedIcon(forSession: remote.id), coordinator.remoteSessionIcon,
                       "on a remote row the weight carries split, so flagging must not claim it")
    }

    func testAStatusIconReplacesThePlainTerminalGlyphUntilTheIndicatorClears() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        let path = try writeIcon(named: "agent.png")
        store.setAgentIndicator(AgentIndicator(status: .active, icon: path), forSession: session.id)
        buildSidebar(for: store)

        let icon = try XCTUnwrap(try renderedIcon(forSession: session.id))
        XCTAssertTrue(icon.isTemplate, "the row tints the icon like the glyph it replaces")
        XCTAssertEqual(icon.accessibilityDescription, "agent")

        store.setAgentIndicator(AgentIndicator(), forSession: session.id)
        coordinator.reconcile()
        XCTAssertEqual(try renderedIcon(forSession: session.id), coordinator.sessionIcon)
    }

    func testAStatusIconStaysThroughAnAutomaticClear() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        let other = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp"))
        store.selectSession(other.id)
        let path = try writeIcon(named: "agent.png")
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true, icon: path), forSession: session.id)
        buildSidebar(for: store)

        store.selectSession(session.id)
        coordinator.reconcile()

        XCTAssertEqual(session.agentIndicator.status, .idle, "the visit must have run the auto-reset")
        XCTAssertNotEqual(try renderedIcon(forSession: session.id), coordinator.sessionIcon,
                          "an idle agent waiting for input keeps its logo")
    }

    func testAnEmSizedSVGIconFillsTheSlot() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let url = stateDir.appendingPathComponent("agent.svg")
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" viewBox="0 0 24 24">"#
            + #"<rect x="4" y="4" width="16" height="16"/></svg>"#
        try Data(svg.utf8).write(to: url)
        store.setAgentIndicator(AgentIndicator(status: .active, icon: url.path), forSession: session.id)
        buildSidebar(for: store)

        let icon = try XCTUnwrap(try renderedIcon(forSession: session.id))
        XCTAssertNotEqual(icon, coordinator.sessionIcon)
        XCTAssertEqual(icon.size, NSSize(width: 16, height: 16), "an em-sized SVG reports 1x1 until fitted to the slot")
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertGreaterThan(rep.colorAt(x: 8, y: 8)?.alphaComponent ?? 0, 0.5, "the drawn icon must not be blank")
    }

    func testASplitRowKeepsItsGlyphOverAStatusIcon() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        store.toggleSplit(session.id)
        store.setAgentIndicator(AgentIndicator(status: .active, icon: try writeIcon(named: "agent.png")), forSession: session.id)
        buildSidebar(for: store)

        XCTAssertEqual(try renderedIcon(forSession: session.id), coordinator.splitSessionIcon)
    }

    func testAMissingStatusIconFallsBackToTheTerminalGlyph() throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        let missing = stateDir.appendingPathComponent("missing.png").path
        store.setAgentIndicator(AgentIndicator(status: .active, icon: missing), forSession: session.id)
        buildSidebar(for: store)

        XCTAssertEqual(try renderedIcon(forSession: session.id), coordinator.sessionIcon)
    }

    func testAStatusIconIsDecodedAgainOnlyWhenTheFileChanges() throws {
        let path = try writeIcon(named: "cached.png")
        let first = try XCTUnwrap(StatusIconImage.image(atPath: path))
        XCTAssertTrue(first === StatusIconImage.image(atPath: path), "an unchanged file must not be decoded again")

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: path)

        XCTAssertFalse(first === StatusIconImage.image(atPath: path), "a rewritten file must be decoded again")
    }

    func testFlaggedRenameRestoresTheLabelAfterAnUnchangedCustomName() async throws {
        try await checkFlaggedRename(customName: "api", edited: "api", expected: "api")
    }

    func testFlaggedRenameRestoresTheLabelAfterAcceptingTheAutomaticName() async throws {
        try await checkFlaggedRename(customName: nil, edited: "automatic", expected: "automatic")
    }

    func testFlaggedRenameRendersTheNormalizedCommittedName() async throws {
        try await checkFlaggedRename(customName: "api", edited: "  worker  ", expected: "worker")
    }

    func testFlaggedRenameCancellationRestoresTheLabel() async throws {
        try await checkFlaggedRename(customName: "api", edited: "discarded", expected: "api", cancelled: true)
    }

    func testRejectedBlankWorkspaceRenameRestoresTheLabel() async throws {
        let store = try XCTUnwrap(library.activeStore)
        buildSidebar(for: store)
        let workspace = store.workspaces[0]
        let node = try XCTUnwrap(coordinator.workspaceNode(forID: workspace.id))
        let field = try beginRename(node)
        field.stringValue = "   "
        try endRename(field)
        await drainRenameCallback()
        let row = outline.row(forItem: node)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.stringValue, workspace.name)
        XCTAssertEqual(store.workspaces[0].name, workspace.name)
    }

    func testRenameCallbackDoesNotReloadAnEditStartedBeforeItRuns() async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        buildSidebar(for: store)
        let node = try sessionNode(session.id)
        let field = try beginRename(node)
        try endRename(field)
        let nextField = try beginRename(node)
        nextField.stringValue = "unfinished"
        await drainRenameCallback()
        XCTAssertTrue(coordinator.renameController.isEditing)
        XCTAssertTrue(try renderedNameField(forSession: session.id) === nextField)
        XCTAssertEqual(nextField.stringValue, "unfinished")
        try endRename(nextField, cancelled: true)
        await drainRenameCallback()
    }

    private func checkFlaggedRename(customName: String?, edited: String, expected: String, cancelled: Bool = false) async throws {
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        session.oscTitle = "automatic"
        session.customName = customName
        session.flagged = true
        store.sidebarMode = .flagged
        let other = try XCTUnwrap(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/other"))
        other.flagged = true
        buildSidebar(for: store)
        let field = try beginRename(sessionNode(session.id))
        XCTAssertEqual(field.stringValue, customName ?? "automatic")
        field.stringValue = edited
        try endRename(field, cancelled: cancelled)
        store.selectSession(other.id)
        await drainRenameCallback()
        let restored = try renderedNameField(forSession: session.id)
        XCTAssertEqual(restored.stringValue, "\(expected) : \(store.workspaces[0].name)")
        XCTAssertEqual(session.customName, expected)
        XCTAssertFalse(restored.isEditable)
        XCTAssertEqual(restored.accessibilityIdentifier(), "session-row")
    }

    private func sessionNode(_ id: UUID) throws -> SidebarNode {
        try XCTUnwrap((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarNode }
            .first { $0.kind == .session && $0.id == id })
    }

    private func beginRename(_ node: SidebarNode) throws -> NSTextField {
        coordinator.renameController.beginEditing(node: node)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: outline.row(forItem: node), makeIfNecessary: true) as? NSTableCellView)
        return try XCTUnwrap(cell.textField)
    }

    private func endRename(_ field: NSTextField, cancelled: Bool = false) throws {
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.string = field.stringValue
        if cancelled {
            XCTAssertTrue(coordinator.renameController.control(field, textView: editor,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        } else {
            XCTAssertTrue(field.window?.makeFirstResponder(nil) == true)
        }
    }

    private func drainRenameCallback() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func buildSidebar(for store: AppStore) {
        outline = SidebarOutlineView()
        coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.narrowSidebar, height: 400))
        scroll.documentView = outline
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.narrowSidebar, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        // over-releases a window the registry may still hold, crashing the host at autorelease-pool pop
        window.isReleasedWhenClosed = false
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
        setSidebarWidth(Self.narrowSidebar)
    }

    /// Both widths these tests use must stay inside the divider's own 160...560 range, or a truncation
    /// threshold that no drag can actually clear would still pass here.
    private static let narrowSidebar: CGFloat = 240

    /// Drives the width the way a divider drag does: the column tracks the outline, and the row views retile
    /// off that. Without it the column keeps its default width and every row measures the same regardless of
    /// the window, which makes a truncation assertion pass for the wrong reason.
    private func setSidebarWidth(_ width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 400))
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        outline.frame = NSRect(x: 0, y: 0, width: width, height: outline.frame.height)
        outline.sizeLastColumnToFit()
        outline.layoutSubtreeIfNeeded()
    }

    private func renderedNameField(forSession id: UUID) throws -> NSTextField {
        let cell = try renderedCell(forSession: id)
        cell.layoutSubtreeIfNeeded()
        return try XCTUnwrap(cell.textField)
    }

    private func renderedCell(forSession id: UUID) throws -> SidebarCellView {
        outline.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { index in
            guard let node = outline.item(atRow: index) as? SidebarNode else { return false }
            return node.kind == .session && node.id == id
        }, "the session row should be visible in the outline")
        return try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
    }

    private func writeIcon(named name: String) throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let url = stateDir.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url.path
    }

    private func renderedIcon(forSession id: UUID) throws -> NSImage? {
        outline.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { index in
            guard let node = outline.item(atRow: index) as? SidebarNode else { return false }
            return node.kind == .session && node.id == id
        }, "the session row should be visible in the outline")
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        return cell.imageView?.image
    }
}
