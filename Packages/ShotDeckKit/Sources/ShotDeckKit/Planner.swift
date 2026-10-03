import Foundation

// MARK: - Shot planning metadata (issue #4)

/// Explicit orientation choices for a planned shot. `portrait` and `landscape`
/// are the only concrete choices offered; an unset field stays `nil` so the
/// editor never fabricates a value the operator did not enter.
public enum ShotOrientation: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
}

/// Explicit camera-movement choices for a planned shot. An unset field stays
/// `nil`; unknown raw strings decode back to `nil` rather than guessing.
public enum ShotMovement: String, Codable, CaseIterable, Sendable {
    case still
    case panLeft = "pan_left"
    case panRight = "pan_right"
    case tiltUp = "tilt_up"
    case tiltDown = "tilt_down"
    case pushIn = "push_in"
    case pullOut = "pull_out"
    case handheld
    case tracking
    case crane
    case gimbal
}

// Planner views and tests identify entities by stable id.
extension Project: Identifiable {}
extension Scene: Identifiable {}
extension Shot: Identifiable {}
extension ContinuityCheck: Identifiable {}

// MARK: - Presentation helpers shared by views and tests

/// Glyphs paired with text labels for every status surface. The glyph is a
/// second channel next to color (issue #4: non-color-only status encoding);
/// VoiceOver reads the accompanying text label instead of the glyph.
public enum StatusGlyph {
    public static func shot(_ status: ShotStatus) -> String {
        switch status {
        case .planned: return "\u{25CB}"   // white circle
        case .active: return "\u{25CF}"    // filled circle
        case .omitted: return "\u{00D7}"   // multiplication sign
        case .archived: return "\u{2193}"  // downwards arrow (pulled)
        case .unknown: return "?"
        }
    }

    public static func scene(_ status: SceneStatus) -> String {
        switch status {
        case .planned: return "\u{25CB}"
        case .active: return "\u{25CF}"
        case .complete: return "\u{2713}"  // check mark
        case .omitted: return "\u{00D7}"
        case .unknown: return "?"
        }
    }

    public static func coverage(_ state: CoverageState?) -> String {
        guard let state else { return "?" }
        switch state {
        case .notStarted: return "\u{25CB}"
        case .attempted: return "\u{2026}" // ellipsis
        case .candidateSelected: return "\u{2713}"
        case .omitted: return "\u{00D7}"
        case .unknown: return "?"
        }
    }
}

/// VoiceOver-ready labels for the same statuses. Every label names the
/// concept explicitly ("Shot status: omitted") so state never rides on
/// color or glyph alone.
public enum StatusCopy {
    public static func shot(_ status: ShotStatus) -> String {
        switch status {
        case .planned: return "Shot status: planned"
        case .active: return "Shot status: active"
        case .omitted: return "Shot status: omitted"
        case .archived: return "Shot status: archived"
        case .unknown: return "Shot status: unknown"
        }
    }

    public static func scene(_ status: SceneStatus) -> String {
        switch status {
        case .planned: return "Scene status: planned"
        case .active: return "Scene status: active"
        case .complete: return "Scene status: complete"
        case .omitted: return "Scene status: omitted"
        case .unknown: return "Scene status: unknown"
        }
    }

    /// Full coverage label including named reasons when present, so an
    /// `unknown` badge announces *why* it is unknown.
    public static func coverage(_ summary: CoverageSummary?) -> String {
        guard let summary else { return "Coverage: unknown (not yet derived)" }
        let stateText: String
        switch summary.state {
        case .notStarted: stateText = "Coverage: not started"
        case .attempted: stateText = "Coverage: attempted"
        case .candidateSelected: stateText = "Coverage: candidate selected"
        case .omitted: stateText = "Coverage: omitted"
        case .unknown: stateText = "Coverage: unknown"
        }
        guard !summary.reasons.isEmpty else { return stateText }
        return stateText + ", reasons: " + summary.reasons.map(\.rawValue).joined(separator: ", ")
    }
}
