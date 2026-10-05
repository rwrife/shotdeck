import Foundation

/// Replay only durable events, in append order. An event pointing to a deleted
/// shot or an unknown event never resumes a possibly incorrect active shot.
public enum ShootSessionContext: Equatable, Sendable {
    case inactive
    case active(ShotID)
    case unresolved

    public static func restore(_ events: [SessionEvent], validShotIDs: Set<ShotID>) -> Self {
        var context: Self = .inactive
        for event in events {
            switch event.kind {
            case .sessionStarted: context = .unresolved
            case .shotSelected:
                if case .inactive = context { context = .unresolved; continue }
                if let id = event.shotID, validShotIDs.contains(id) {
                    context = .active(id)
                } else {
                    context = .unresolved
                }
            case .sessionEnded: context = .inactive
            case .unknown: context = .unresolved
            case .takeAppended, .candidateChanged: break
            }
        }
        return context
    }
}

/// A logic-only seam, NOT a claim of dual-display OS support. The current
/// iPhone uses the folded single-focus layout; future hardware integration
/// may supply a fold state without changing shoot domain or storage logic.
public struct ShootWorkspaceLayout: Equatable, Sendable {
    public enum FoldState: Sendable { case folded, unfolded, unknown }
    public enum Panel: Sendable { case activeShot, takeLedger }
    public let panels: [Panel]

    public init(foldState: FoldState) {
        panels = foldState == .unfolded ? [.activeShot, .takeLedger] : [.activeShot]
    }
}
