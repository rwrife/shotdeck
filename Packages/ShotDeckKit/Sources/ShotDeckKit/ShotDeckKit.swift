/// ShotDeckKit — pure-domain namespace.
///
/// Issue #1 intentionally ships only bootstrap constants. Later slices add
/// entities, coverage semantics, and persistence bridges.
public enum ShotDeckKit {
    /// Namespace marker for domain tests.
    public static let domain = "ShotDeckKit"

    /// Tracks the milestone delivered by this package revision.
    public static let milestone = "M1-native-bootstrap"
}
