/// StatusReset is which keystroke clears a `blocked` or `completed` glyph: the first key, a submit (Return),
/// or none. Raw-stored in `AppSettings.statusReset`, resolved by `effectiveStatusReset`.
public enum StatusReset: String, Codable, Sendable, CaseIterable {
    case firstKey
    case enter
    case never
}

/// StatusKeystroke is what one keystroke means to the glyph: an interrupt (Escape or Ctrl-C), a submit
/// (Return with no modifier, or injected text carrying a newline), or plain typing.
public enum StatusKeystroke: Sendable, Equatable {
    case interrupt
    case submit
    case other
}

/// AgentStatus is the per-session agent state driven over the control channel (`session.status`).
/// `idle` means nothing is shown; the other cases each render a tinted sidebar glyph.
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle, active, completed, blocked

    /// True for the states attention navigation (⌃⌥↑/↓, `session.go next-attention|prev-attention`) steps
    /// through: a `blocked` prompt or a `completed` run, not `active` (still working) or `idle` (no glyph).
    public var needsAttention: Bool { self == .blocked || self == .completed }

    /// Whether a keystroke in the session's terminal should clear this glyph back to idle. `blocked` and
    /// `completed` clear as `reset` says: on any key (you've engaged with the prompt / the finished result),
    /// on a submit only (the reply is sent, so a half-typed one keeps the glyph), or never. Under submit-only
    /// an interrupt (Escape or Ctrl-C) also clears `blocked`: cancelling a prompt fires no hook, so nothing
    /// else drops it. `active` clears ONLY on an interrupt in every mode, so typing while the agent works
    /// keeps the "working" glyph, and a prompt cancelled before any `blocked` arrived does not stay `active`.
    func clearedBy(keystroke: StatusKeystroke, reset: StatusReset) -> Bool {
        switch self {
        case .blocked, .completed:
            switch reset {
            case .firstKey: return true
            case .enter: return keystroke == .submit || (self == .blocked && keystroke == .interrupt)
            case .never: return false
            }
        case .active: return keystroke == .interrupt
        case .idle: return false
        }
    }

    /// Sort priority for the attention list, lower first. `idle` is never sorted — idle sessions are filtered
    /// out before the list is built — but ranks last so an accidental inclusion sorts after the rest.
    public var attentionRank: Int {
        switch self {
        case .blocked: return 0
        case .active: return 1
        case .completed: return 2
        case .idle: return 3
        }
    }

    /// The sound to play for a `session.status` call, or nil for none: an explicit per-call sound
    /// (`session.status --sound`) wins, else the configured `blockedDefault` (Settings "Blocked sound") plays
    /// ONLY for `blocked`; empty strings count as unset. The app resolves the name with `NSSound(named:)`.
    public func effectiveSound(perCall: String?, blockedDefault: String?) -> String? {
        if let perCall, !perCall.isEmpty { return perCall }
        if self == .blocked, let blockedDefault, !blockedDefault.isEmpty { return blockedDefault }
        return nil
    }

    /// symbolName resolves the SF Symbol for the status glyph, shared by the AppKit sidebar and the SwiftUI
    /// attention list: the per-call `override` (from `session.status --shape`) wins, else the `configured`
    /// Settings shape, else `StatusShape.circle`. `idle` renders no glyph, so its "" is filtered out before use.
    public func symbolName(override: StatusShape?, configured: StatusShape?) -> String {
        guard self != .idle else { return "" }
        return (override ?? configured ?? .circle).symbolName
    }

    /// Tooltip for a visible status glyph. Idle renders no glyph and therefore has no tooltip.
    public var tooltipText: String? {
        self == .idle ? nil : "Agent status: \(rawValue.capitalized)"
    }
}

/// StatusPane records which pane set the current agent status, in the `--pane` control vocabulary it also
/// serializes as (`left`=main, `right`=split, `scratch`). Pane-scoped keystroke-clear and pane-aware
/// navigation read it off `AgentIndicator` to know which surface blocked.
public enum StatusPane: String, Codable, Sendable, CaseIterable {
    case left, right, scratch

    /// Parses every accepted positional or role spelling while keeping `rawValue` stable for read-back and
    /// the `AGTERM_PANE` environment (`left|right|scratch`).
    public init?(controlName: String) {
        switch controlName {
        case "left", "top", "primary": self = .left
        case "right", "bottom", "split": self = .right
        case "scratch": self = .scratch
        default: return nil
        }
    }
}

/// StatusShape is the silhouette a status glyph draws, so shape carries the state alongside the tint. Every
/// shape is plain, with no interior mark, selectable per status in Settings or per call via
/// `session.status --shape`; `circle` is what an unset status draws. The raw value is the SF Symbol base name.
public enum StatusShape: String, Codable, Sendable, CaseIterable {
    case circle, square, triangle, diamond, capsule, star

    /// SF Symbol name for the shape — the `.fill` variant, so every glyph is a solid silhouette, not an outline.
    public var symbolName: String { "\(rawValue).fill" }

    /// The human-facing name ("Triangle"): the Settings picker's per-option accessibility label and its value.
    public var displayName: String { rawValue.capitalized }

    /// The accepted names pipe-joined — the compact form the control server's rejection message uses. Derived
    /// from `allCases`, like `WatermarkConfig.validFits`, so no message can go stale.
    public static var validNamesList: String { validNames.joined(separator: "|") }

    /// The accepted names comma-joined — the prose form for `agtermctl --shape` help and its local rejection.
    public static var validNamesPhrase: String { validNames.joined(separator: ", ") }

    private static var validNames: [String] { allCases.map(\.rawValue) }
}

/// StatusIconChange is what one `session.status` call does to the sticky row icon: an omitted `--icon` keeps
/// it, a path replaces it, and `none` clears it.
public enum StatusIconChange: Equatable, Sendable {
    case keep
    case set(String)
    case clear

    /// The `--icon` value that clears; never a valid path, which must be absolute.
    public static let noneName = "none"

    /// Parses a raw `--icon` value, nil for one that is neither `noneName` nor a valid icon path.
    public init?(_ raw: String?) {
        switch raw {
        case nil: self = .keep
        case Self.noneName?: self = .clear
        case let path? where AgentIndicator.isValidIconPath(path): self = .set(path)
        default: return nil
        }
    }

    public func applied(to current: String?) -> String? {
        switch self {
        case .keep: return current
        case .set(let path): return path
        case .clear: return nil
        }
    }
}

/// AgentIndicator is the per-session agent status value: state, blink, autoReset, per-call color, shape and
/// icon overrides, and the pane that set it. Ephemeral (never persisted) and set only via the control API.
public struct AgentIndicator: Equatable, Sendable {
    public var status: AgentStatus = .idle
    /// blink makes the visible glyph pulse for attention.
    public var blink: Bool = false
    /// autoReset resets the indicator to idle once the session is visited (selected) — caller-set and
    /// status-agnostic, like blink.
    public var autoReset: Bool = false
    /// color, when set, is a `#rrggbb` hex overriding the Settings tint for this glyph only; it rides the
    /// ephemeral indicator, so the next `session.status` without a color discards it. nil = the default tint.
    public var color: String?
    /// shape, when set, overrides the Settings-configured silhouette for this glyph only, discarded like
    /// `color`. nil falls back to the Settings shape, else the default plain circle.
    public var shape: StatusShape?
    /// icon, when set, is an image path replacing the row's plain terminal glyph. It names the agent, not the
    /// state, so unlike `color` it is sticky (`StatusIconChange`) and survives `cleared`.
    public var icon: String?
    /// statusPane records which pane set this status; nil is unspecified and treated as `.left` (main) by the
    /// clear logic.
    public var statusPane: StatusPane?

    public init(status: AgentStatus = .idle, blink: Bool = false, autoReset: Bool = false,
                color: String? = nil, shape: StatusShape? = nil, icon: String? = nil, statusPane: StatusPane? = nil) {
        self.status = status
        self.blink = blink
        self.autoReset = autoReset
        self.color = color
        self.shape = shape
        self.icon = icon
        self.statusPane = statusPane
    }

    /// cleared is the idle indicator an automatic clear leaves: keystroke and auto-reset clears keep the icon.
    public var cleared: AgentIndicator { AgentIndicator(icon: icon) }

    private static let iconExtensions = ["png", "jpg", "jpeg", "pdf", "svg"]

    /// The accepted icon types as prose (".png, .jpg, .jpeg, .pdf or .svg") for both rejection messages.
    public static var iconTypesPhrase: String {
        let names = iconExtensions.map { ".\($0)" }
        return names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
    }

    /// The `session.status` reply note for an icon the row will not draw, nil when it will.
    public static func iconNote(decodes: Bool, plainRow: Bool) -> String? {
        if !decodes { return "icon not shown: the file is missing or is not an image" }
        if !plainRow { return "icon not shown while the row draws its split, flagged or remote glyph" }
        return nil
    }

    /// isValidIconPath accepts an absolute, control-free path to one of `iconExtensions`.
    public static func isValidIconPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), WatermarkConfig.isValidImagePath(path),
              let name = path.split(separator: "/").last, let dot = name.lastIndex(of: ".") else { return false }
        return iconExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// clearedBy: a keystroke from `pane` clears this indicator only when that pane owns the current status and
    /// `AgentStatus.clearedBy(keystroke:reset:)` allows it, so foreground typing can't wipe a background
    /// pane's status.
    public func clearedBy(pane: StatusPane, keystroke: StatusKeystroke, reset: StatusReset) -> Bool {
        (statusPane ?? .left) == pane && status.clearedBy(keystroke: keystroke, reset: reset)
    }

    /// normalizedPane: the tag as the store keeps it — a `.right` tag on a splitless session folds to `.left`,
    /// since a promoted survivor's shell keeps its baked `AGTERM_PANE=right` and the sole (`.left`-role-aware)
    /// pane could never keystroke-clear a `.right` tag. nil is preserved so the read-back omits the field.
    func normalizedPane(hasSplit: Bool) -> StatusPane? {
        statusPane == .right && !hasSplit ? .left : statusPane
    }
}
