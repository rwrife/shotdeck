/// ShotDeckKit — pure-domain namespace.
///
/// Public package metadata. Domain entities and coverage semantics live in
/// `Domain.swift`; persistence bridges remain a later slice.
public enum ShotDeckKit {
    /// Namespace marker for domain tests.
    public static let domain = "ShotDeckKit"

    /// Tracks the milestone delivered by this package revision.
    public static let milestone = "M2-domain-coverage"
}
