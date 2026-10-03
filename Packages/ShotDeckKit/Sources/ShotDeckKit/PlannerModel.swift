import Foundation

// MARK: - Planner document model (issue #4)

/// Validation failures surfaced by planner mutations. The UI shows the
/// `errorDescription`; the model remains the enforcement boundary so bad
/// input can never enter persistence regardless of UI state.
public enum PlannerValidationError: Error, Equatable, Sendable, LocalizedError {
    case emptyTitle(entity: String)
    case unknownProject(ProjectID)
    case unknownScene(SceneID)
    case unknownShot(ShotID)
    case shotBelongsToOtherScene(expected: SceneID, actual: SceneID)
    case invalidReferenceFilename(String)

    public var errorDescription: String? {
        switch self {
        case let .emptyTitle(entity):
            return "\(entity) title cannot be empty."
        case let .unknownProject(id):
            return "Project \(id.rawValue) does not exist."
        case let .unknownScene(id):
            return "Scene \(id.rawValue) does not exist."
        case let .unknownShot(id):
            return "Shot \(id.rawValue) does not exist."
        case let .shotBelongsToOtherScene(expected, actual):
            return "Shot belongs to scene \(actual.rawValue), not \(expected.rawValue)."
        case let .invalidReferenceFilename(name):
            return "Reference filename “\(name)” is not a plain file name."
        }
    }
}

/// Normalizes operator-entered framing tags: trims whitespace, drops empty
/// entries, removes duplicates, preserves first-seen order. Deterministic so
/// round-trip fixtures stay stable.
public func normalizeFramingTags(_ raw: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for tag in raw {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
        seen.insert(trimmed)
        result.append(trimmed)
    }
    return result
}

/// Normalizes optional free-text fields into explicit absence.
public func normalizedOptionalText(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    return trimmed
}

/// Validates a user-supplied reference file name: plain name only, no path
/// separators or traversal. Returns normalized value or nil for empty input.
public func normalizedReferenceFilename(_ raw: String?) throws -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else { return nil }
    if trimmed.contains("/") || trimmed.contains("\\") || trimmed == "." || trimmed == ".." {
        throw PlannerValidationError.invalidReferenceFilename(trimmed)
    }
    return trimmed
}

/// Applies a `List` move (IndexSet semantics) to an ordered id array and
/// returns the new order. Indices outside the array are clamped so a stale
/// list snapshot can never crash or fabricate entries.
public func applyingMove<Element: Hashable>(
    to order: [Element],
    moving elements: IndexSet,
    toDestination destination: Int
) -> [Element] {
    var remaining = order.enumerated()
        .filter { !elements.contains($0.offset) }
        .map(\.element)
    let moved = elements.sorted().compactMap { order.indices.contains($0) ? order[$0] : nil }
    let insertAt = min(max(destination - elements.filter { $0 < destination }.count, 0), remaining.count)
    remaining.insert(contentsOf: moved, at: insertAt)
    return remaining
}

/// The planner document: projects with ordered scene lists, scenes with
/// ordered shot lists, and the shot dictionary itself. All planner
/// mutations route through this model; ordering is explicit (stored id
/// lists), never implicit re-sorting.
public struct PlannerModel: Equatable {
    public private(set) var projects: [Project]
    public private(set) var scenesByID: [SceneID: Scene]
    public private(set) var shotsByID: [ShotID: Shot]

    public init(projects: [Project], scenes: [Scene], shots: [Shot]) {
        var scenesByID: [SceneID: Scene] = [:]
        for scene in scenes { scenesByID[scene.id] = scene }
        var shotsByID: [ShotID: Shot] = [:]
        for shot in shots { shotsByID[shot.id] = shot }

        // Drop listed children whose rows are gone; never fabricate rows.
        var repairedProjects: [Project] = []
        for var project in projects {
            project.sceneIDs = project.sceneIDs.filter { scenesByID[$0] != nil }
            repairedProjects.append(project)
        }
        var repairedScenes: [SceneID: Scene] = [:]
        for (id, var scene) in scenesByID {
            scene.shotIDs = scene.shotIDs.filter { shotsByID[$0] != nil }
            repairedScenes[id] = scene
        }

        self.projects = repairedProjects
        self.scenesByID = repairedScenes
        self.shotsByID = shotsByID
    }

    // MARK: - Queries

    public func project(_ id: ProjectID) -> Project? {
        projects.first { $0.id == id }
    }

    public func scene(_ id: SceneID) -> Scene? {
        scenesByID[id]
    }

    public func shot(_ id: ShotID) -> Shot? {
        shotsByID[id]
    }

    public func scenes(in projectID: ProjectID) -> [Scene] {
        guard let project = project(projectID) else { return [] }
        return project.sceneIDs.compactMap { scenesByID[$0] }
    }

    public func shots(in sceneID: SceneID) -> [Shot] {
        guard let scene = scenesByID[sceneID] else { return [] }
        return scene.shotIDs.compactMap { shotsByID[$0] }
    }

    /// All shots across every scene of one project in document order.
    public func allShots(in projectID: ProjectID) -> [Shot] {
        scenes(in: projectID).flatMap { shots(in: $0.id) }
    }

    /// Reusable framing tags used by this project, first-seen order.
    public func knownTags(in projectID: ProjectID) -> [String] {
        normalizeFramingTags(allShots(in: projectID).flatMap(\.framingTags))
    }

    private func projectIndex(for id: ProjectID) throws -> Int {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw PlannerValidationError.unknownProject(id)
        }
        return index
    }

    private func sceneRequiring(_ id: SceneID) throws -> Scene {
        guard let scene = scenesByID[id] else {
            throw PlannerValidationError.unknownScene(id)
        }
        return scene
    }

    // MARK: - Project mutations

    public mutating func createProject(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Untitled project" : trimmed
        projects.append(Project(title: name))
    }

    public mutating func renameProject(_ id: ProjectID, title: String) throws {
        let index = try projectIndex(for: id)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlannerValidationError.emptyTitle(entity: "Project")
        }
        projects[index].title = trimmed
    }

    public mutating func setProjectStatus(_ id: ProjectID, status: ProjectStatus) throws {
        let index = try projectIndex(for: id)
        projects[index].status = status
    }

    /// Deletes the project and its scene/shot documents from the model.
    /// Take ledgers are separate append-only evidence and are unaffected.
    public mutating func deleteProject(_ id: ProjectID) throws {
        let index = try projectIndex(for: id)
        let sceneIDs = projects[index].sceneIDs
        projects.remove(at: index)
        for sceneID in sceneIDs {
            if let scene = scenesByID.removeValue(forKey: sceneID) {
                for shotID in scene.shotIDs { shotsByID.removeValue(forKey: shotID) }
            }
        }
    }

    // MARK: - Scene mutations

    @discardableResult
    public mutating func addScene(to projectID: ProjectID, title: String) throws -> Scene {
        let index = try projectIndex(for: projectID)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlannerValidationError.emptyTitle(entity: "Scene")
        }
        let scene = Scene(projectID: projectID, title: trimmed)
        scenesByID[scene.id] = scene
        projects[index].sceneIDs.append(scene.id)
        return scene
    }

    public mutating func renameScene(_ id: SceneID, title: String) throws {
        var scene = try sceneRequiring(id)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlannerValidationError.emptyTitle(entity: "Scene")
        }
        scene.title = trimmed
        scenesByID[id] = scene
    }

    public mutating func setSceneStatus(_ id: SceneID, status: SceneStatus) throws {
        var scene = try sceneRequiring(id)
        scene.status = status
        scenesByID[id] = scene
    }

    public mutating func moveScene(
        _ projectID: ProjectID, moving elements: IndexSet, toDestination destination: Int
    ) throws {
        let index = try projectIndex(for: projectID)
        projects[index].sceneIDs = applyingMove(
            to: projects[index].sceneIDs, moving: elements, toDestination: destination)
    }

    /// Deletes a scene and every shot it lists (model side; the store
    /// applies the matching cascade).
    public mutating func deleteScene(_ id: SceneID) throws {
        let scene = try sceneRequiring(id)
        for shotID in scene.shotIDs { shotsByID.removeValue(forKey: shotID) }
        scenesByID.removeValue(forKey: id)
        let index = try projectIndex(for: scene.projectID)
        projects[index].sceneIDs.removeAll { $0 == id }
    }

    // MARK: - Shot mutations

    @discardableResult
    public mutating func addShot(to sceneID: SceneID, title: String) throws -> Shot {
        var target = try sceneRequiring(sceneID)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlannerValidationError.emptyTitle(entity: "Shot")
        }
        let shot = Shot(sceneID: sceneID, title: trimmed)
        shotsByID[shot.id] = shot
        target.shotIDs.append(shot.id)
        scenesByID[sceneID] = target
        return shot
    }

    /// Validates and stores an edited shot (title, tags, framing metadata).
    public mutating func updateShot(_ shot: Shot) throws {
        guard shotsByID[shot.id] != nil else {
            throw PlannerValidationError.unknownShot(shot.id)
        }
        var edited = shot
        let trimmed = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlannerValidationError.emptyTitle(entity: "Shot")
        }
        edited.title = trimmed
        edited.framingTags = normalizeFramingTags(edited.framingTags)
        edited.lensDescription = normalizedOptionalText(edited.lensDescription)
        edited.actionNotes = edited.actionNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.referenceFilename = try normalizedReferenceFilename(edited.referenceFilename)
        edited.referenceCaption = normalizedOptionalText(edited.referenceCaption)
        shotsByID[shot.id] = edited
    }

    public mutating func setShotStatus(_ id: ShotID, status: ShotStatus) throws {
        guard var shot = shotsByID[id] else {
            throw PlannerValidationError.unknownShot(id)
        }
        shot.status = status
        shotsByID[id] = shot
    }

    public mutating func moveShot(
        _ sceneID: SceneID, moving elements: IndexSet, toDestination destination: Int
    ) throws {
        var target = try sceneRequiring(sceneID)
        target.shotIDs = applyingMove(
            to: target.shotIDs, moving: elements, toDestination: destination)
        scenesByID[sceneID] = target
    }

    public mutating func deleteShot(_ id: ShotID) throws {
        guard let shot = shotsByID.removeValue(forKey: id) else {
            throw PlannerValidationError.unknownShot(id)
        }
        if var scene = scenesByID[shot.sceneID] {
            scene.shotIDs.removeAll { $0 == id }
            scenesByID[shot.sceneID] = scene
        }
    }

    // MARK: - Full-document snapshot (round-trip with the store)

    public var scenes: [Scene] {
        scenesByID.values.sorted { $0.title < $1.title }
    }

    public var shots: [Shot] {
        shotsByID.values.sorted { $0.title < $1.title }
    }
}
