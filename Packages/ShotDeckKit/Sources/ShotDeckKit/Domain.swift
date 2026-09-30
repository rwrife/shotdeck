import Foundation

// MARK: - Stable identifiers

public struct ProjectID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct SceneID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct ShotID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct TakeID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct ContinuityCheckID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct SessionEventID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

// MARK: - Domain entities

public enum ProjectStatus: String, Codable, Sendable {
    case active
    case archived
    case unknown
}

public struct Project: Equatable, Codable, Sendable {
    public let id: ProjectID
    public var title: String
    public var status: ProjectStatus
    /// Scene order is explicit and survives persistence round trips.
    public var sceneIDs: [SceneID]

    public init(
        id: ProjectID = ProjectID(),
        title: String,
        status: ProjectStatus = .active,
        sceneIDs: [SceneID] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.sceneIDs = sceneIDs
    }
}

public enum SceneStatus: String, Codable, Sendable {
    case planned
    case active
    case complete
    case omitted
    case unknown
}

public struct Scene: Equatable, Codable, Sendable {
    public let id: SceneID
    public let projectID: ProjectID
    public var title: String
    public var status: SceneStatus
    /// Shot order is explicit and survives persistence round trips.
    public var shotIDs: [ShotID]

    public init(
        id: SceneID = SceneID(),
        projectID: ProjectID,
        title: String,
        status: SceneStatus = .planned,
        shotIDs: [ShotID] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.status = status
        self.shotIDs = shotIDs
    }
}

public enum ShotStatus: String, Codable, Sendable {
    case planned
    case active
    case omitted
    case unknown
}

public struct Shot: Equatable, Codable, Sendable {
    public let id: ShotID
    public let sceneID: SceneID
    public var title: String
    public var status: ShotStatus
    /// `nil` means continuity requirements are unavailable. An empty array
    /// explicitly means this shot has no continuity requirements.
    public var requiredContinuityCheckIDs: [ContinuityCheckID]?

    public init(
        id: ShotID = ShotID(),
        sceneID: SceneID,
        title: String,
        status: ShotStatus = .planned,
        requiredContinuityCheckIDs: [ContinuityCheckID]? = []
    ) {
        self.id = id
        self.sceneID = sceneID
        self.title = title
        self.status = status
        self.requiredContinuityCheckIDs = requiredContinuityCheckIDs
    }
}

public enum TakeRating: String, Codable, Sendable {
    case unreviewed
    case keep
    case reject
    case unknown
}

/// An immutable take ledger record. Corrections append a new record whose
/// `revisionOf` points at the superseded record; callers never mutate history.
public struct Take: Equatable, Codable, Sendable {
    public let id: TakeID
    public let shotID: ShotID
    public let recordedAt: Date?
    public let durationSeconds: Double?
    public let cameraDescription: String?
    public let rating: TakeRating
    public let notes: String
    public let revisionOf: TakeID?

    public init(
        id: TakeID = TakeID(),
        shotID: ShotID,
        recordedAt: Date?,
        durationSeconds: Double? = nil,
        cameraDescription: String?,
        rating: TakeRating = .unreviewed,
        notes: String = "",
        revisionOf: TakeID? = nil
    ) {
        self.id = id
        self.shotID = shotID
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.cameraDescription = cameraDescription
        self.rating = rating
        self.notes = notes
        self.revisionOf = revisionOf
    }
}

public enum ContinuityCheckStatus: String, Codable, Sendable {
    case pending
    case matched
    case mismatch
    case notApplicable = "not_applicable"
    case unknown
}

public struct ContinuityCheck: Equatable, Codable, Sendable {
    public let id: ContinuityCheckID
    public let shotID: ShotID
    public var label: String
    public var status: ContinuityCheckStatus
    public var notes: String

    public init(
        id: ContinuityCheckID = ContinuityCheckID(),
        shotID: ShotID,
        label: String,
        status: ContinuityCheckStatus = .pending,
        notes: String = ""
    ) {
        self.id = id
        self.shotID = shotID
        self.label = label
        self.status = status
        self.notes = notes
    }
}

public enum SessionEventKind: String, Codable, Sendable {
    case sessionStarted = "session_started"
    case shotSelected = "shot_selected"
    case takeAppended = "take_appended"
    case candidateChanged = "candidate_changed"
    case sessionEnded = "session_ended"
    case unknown
}

public struct SessionEvent: Equatable, Codable, Sendable {
    public let id: SessionEventID
    public let projectID: ProjectID
    public let occurredAt: Date
    public let kind: SessionEventKind
    public let shotID: ShotID?
    public let takeID: TakeID?

    public init(
        id: SessionEventID = SessionEventID(),
        projectID: ProjectID,
        occurredAt: Date,
        kind: SessionEventKind,
        shotID: ShotID? = nil,
        takeID: TakeID? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.occurredAt = occurredAt
        self.kind = kind
        self.shotID = shotID
        self.takeID = takeID
    }
}

// MARK: - Append-only take ledger

public enum CandidateTakeSelection: Equatable, Codable, Sendable {
    /// The operator explicitly has not selected a candidate.
    case unresolved
    case selected(TakeID)
    /// Imported or damaged data did not preserve whether a selection existed.
    case unknown
}

public enum TakeLedgerError: Error, Equatable, Sendable {
    case duplicateTakeID(TakeID)
    case mixedShotIDs(expected: ShotID, actual: ShotID)
    case revisedTakeMissing(TakeID)
    case revisedTakeFromDifferentShot(TakeID)
    case takeAlreadyRevised(TakeID)
    case candidateTakeMissing(TakeID)
}

/// Records take history in insertion order. There is deliberately no edit,
/// replace, or remove operation. Corrections are appended as revisions.
public struct TakeLedger: Equatable, Codable, Sendable {
    public private(set) var entries: [Take]
    public private(set) var candidateSelection: CandidateTakeSelection

    private enum CodingKeys: String, CodingKey {
        case entries
        case candidateSelection
    }

    public init(
        entries: [Take] = [],
        candidateSelection: CandidateTakeSelection = .unresolved
    ) throws {
        self.entries = []
        self.candidateSelection = .unresolved
        for entry in entries {
            try append(entry)
        }
        try setCandidateSelection(candidateSelection)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEntries = try values.decode([Take].self, forKey: .entries)
        let decodedSelection = try values.decode(
            CandidateTakeSelection.self,
            forKey: .candidateSelection
        )
        try self.init(entries: decodedEntries, candidateSelection: decodedSelection)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(entries, forKey: .entries)
        try values.encode(candidateSelection, forKey: .candidateSelection)
    }

    public var shotID: ShotID? { entries.first?.shotID }

    /// Latest non-superseded records in original append order.
    public var currentTakes: [Take] {
        let superseded = Set(entries.compactMap(\.revisionOf))
        return entries.filter { !superseded.contains($0.id) }
    }

    public mutating func append(_ take: Take) throws {
        if entries.contains(where: { $0.id == take.id }) {
            throw TakeLedgerError.duplicateTakeID(take.id)
        }
        if let expected = shotID, expected != take.shotID {
            throw TakeLedgerError.mixedShotIDs(expected: expected, actual: take.shotID)
        }
        if let revisedID = take.revisionOf {
            guard let revised = entries.first(where: { $0.id == revisedID }) else {
                throw TakeLedgerError.revisedTakeMissing(revisedID)
            }
            guard revised.shotID == take.shotID else {
                throw TakeLedgerError.revisedTakeFromDifferentShot(revisedID)
            }
            if entries.contains(where: { $0.revisionOf == revisedID }) {
                throw TakeLedgerError.takeAlreadyRevised(revisedID)
            }
        }
        entries.append(take)
    }

    public mutating func selectCandidate(_ takeID: TakeID) throws {
        try setCandidateSelection(.selected(takeID))
    }

    public mutating func clearCandidate() {
        candidateSelection = .unresolved
    }

    public mutating func markCandidateSelectionUnknown() {
        candidateSelection = .unknown
    }

    private mutating func setCandidateSelection(_ selection: CandidateTakeSelection) throws {
        if case let .selected(takeID) = selection,
           !entries.contains(where: { $0.id == takeID }) {
            throw TakeLedgerError.candidateTakeMissing(takeID)
        }
        candidateSelection = selection
    }
}

// MARK: - Coverage derivation

public enum CoverageState: String, Codable, Sendable {
    case notStarted = "not_started"
    case attempted
    case candidateSelected = "candidate_selected"
    case omitted
    case unknown
}

public enum CoverageReason: String, Codable, Sendable {
    case noTakes = "no_takes"
    case candidateNotSelected = "candidate_not_selected"
    case explicitCandidateSelected = "explicit_candidate_selected"
    case explicitlyOmitted = "explicitly_omitted"
    case shotStatusUnknown = "shot_status_unknown"
    case takeLedgerUnavailable = "take_ledger_unavailable"
    case takeLedgerShotMismatch = "take_ledger_shot_mismatch"
    case candidateSelectionUnknown = "candidate_selection_unknown"
    case selectedCandidateMissing = "selected_candidate_missing"
    case selectedCandidateSuperseded = "selected_candidate_superseded"
    case candidateTimingMissing = "candidate_timing_missing"
    case candidateCameraMissing = "candidate_camera_missing"
    case continuityRequirementsUnavailable = "continuity_requirements_unavailable"
    case continuityDataUnavailable = "continuity_data_unavailable"
    case continuityCheckMissing = "continuity_check_missing"
    case continuityShotMismatch = "continuity_shot_mismatch"
    case continuityStatusUnknown = "continuity_status_unknown"
    case continuityPending = "continuity_pending"
    case continuityMismatch = "continuity_mismatch"
}

public struct CoverageSummary: Equatable, Codable, Sendable {
    public let shotID: ShotID
    public let state: CoverageState
    public let reasons: [CoverageReason]
    public let takeCount: Int
    public let candidateTakeID: TakeID?

    public init(
        shotID: ShotID,
        state: CoverageState,
        reasons: [CoverageReason],
        takeCount: Int,
        candidateTakeID: TakeID?
    ) {
        self.shotID = shotID
        self.state = state
        self.reasons = reasons
        self.takeCount = takeCount
        self.candidateTakeID = candidateTakeID
    }
}

public enum CoverageEngine {
    /// Derives coverage solely from explicit domain facts. Missing ledger,
    /// selection, timing, camera, or required-continuity data yields `unknown`
    /// rather than promoting the shot to `candidate_selected`.
    public static func derive(
        shot: Shot,
        ledger: TakeLedger?,
        continuityChecks: [ContinuityCheck]?
    ) -> CoverageSummary {
        if shot.status == .unknown {
            return summary(shot, .unknown, [.shotStatusUnknown], ledger)
        }
        if shot.status == .omitted {
            return summary(shot, .omitted, [.explicitlyOmitted], ledger)
        }
        guard let ledger else {
            return summary(shot, .unknown, [.takeLedgerUnavailable], nil)
        }
        if let ledgerShotID = ledger.shotID, ledgerShotID != shot.id {
            return summary(shot, .unknown, [.takeLedgerShotMismatch], ledger)
        }
        guard !ledger.entries.isEmpty else {
            return summary(shot, .notStarted, [.noTakes], ledger)
        }

        switch ledger.candidateSelection {
        case .unknown:
            return summary(shot, .unknown, [.candidateSelectionUnknown], ledger)
        case .unresolved:
            return summary(shot, .attempted, [.candidateNotSelected], ledger)
        case let .selected(candidateID):
            guard let candidate = ledger.entries.first(where: { $0.id == candidateID }) else {
                return summary(shot, .unknown, [.selectedCandidateMissing], ledger)
            }
            if ledger.currentTakes.allSatisfy({ $0.id != candidateID }) {
                return summary(shot, .unknown, [.selectedCandidateSuperseded], ledger)
            }
            guard candidate.recordedAt != nil,
                  let duration = candidate.durationSeconds,
                  duration > 0 else {
                return summary(shot, .unknown, [.candidateTimingMissing], ledger)
            }
            guard let camera = candidate.cameraDescription,
                  !camera.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return summary(shot, .unknown, [.candidateCameraMissing], ledger)
            }
            guard let requiredIDs = shot.requiredContinuityCheckIDs else {
                return summary(shot, .unknown, [.continuityRequirementsUnavailable], ledger)
            }
            guard !requiredIDs.isEmpty else {
                return summary(shot, .candidateSelected, [.explicitCandidateSelected], ledger)
            }
            guard let continuityChecks else {
                return summary(shot, .unknown, [.continuityDataUnavailable], ledger)
            }

            let checksByID = Dictionary(uniqueKeysWithValues: continuityChecks.map { ($0.id, $0) })
            var reasons: [CoverageReason] = [.explicitCandidateSelected]
            for requiredID in requiredIDs {
                guard let check = checksByID[requiredID] else {
                    return summary(shot, .unknown, [.continuityCheckMissing], ledger)
                }
                guard check.shotID == shot.id else {
                    return summary(shot, .unknown, [.continuityShotMismatch], ledger)
                }
                guard check.status != .unknown else {
                    return summary(shot, .unknown, [.continuityStatusUnknown], ledger)
                }
                if check.status == .pending {
                    reasons.append(.continuityPending)
                } else if check.status == .mismatch {
                    reasons.append(.continuityMismatch)
                }
            }
            return summary(shot, .candidateSelected, reasons, ledger)
        }
    }

    private static func summary(
        _ shot: Shot,
        _ state: CoverageState,
        _ reasons: [CoverageReason],
        _ ledger: TakeLedger?
    ) -> CoverageSummary {
        let selectedID: TakeID?
        if case let .selected(id) = ledger?.candidateSelection {
            selectedID = id
        } else {
            selectedID = nil
        }
        return CoverageSummary(
            shotID: shot.id,
            state: state,
            reasons: reasons,
            takeCount: ledger?.entries.count ?? 0,
            candidateTakeID: selectedID
        )
    }
}
