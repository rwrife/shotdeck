import SwiftUI
import ShotDeckKit

// SwiftUI also exports a `Scene` type (window group abstraction). Planner
// views always mean the domain scene, so pin the name at file scope —
// qualification, not a domain rename.
private typealias Scene = ShotDeckKit.Scene

/// Project list root (issue #4): create / rename / archive / delete.
struct ProjectListView: View {
    @Environment(PlannerStore.self) private var store

    @State private var showingCreate = false
    @State private var newProjectTitle = ""
    @State private var pendingDeletion: Project?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.projects.isEmpty {
                    ContentUnavailableView(
                        "No projects yet",
                        systemImage: "film",
                        description: Text("Create a project to start planning shots.")
                    )
                    .accessibilityIdentifier("projectList.emptyState")
                } else {
                    List {
                        ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                            NavigationLink(value: project.id) {
                                ProjectRow(project: project)
                            }
                            .accessibilityIdentifier("projectRow.index.\(index)")
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDeletion = project
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .accessibilityIdentifier("project.delete.index.\(index)")

                                Button {
                                    toggleArchive(project)
                                } label: {
                                    Label(
                                        project.status == .archived ? "Unarchive" : "Archive",
                                        systemImage: project.status == .archived ? "arrow.up.bin" : "archivebox"
                                    )
                                }
                                .tint(.orange)
                                .accessibilityIdentifier("project.archive.index.\(index)")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Projects")
            .navigationDestination(for: ProjectID.self) { id in
                if let project = store.project(id) {
                    SceneListView(project: project)
                } else {
                    // Project deleted while navigating — say so honestly.
                    Text("This project is no longer here.")
                        .accessibilityIdentifier("projectDetail.gone")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCreate = true
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .accessibilityIdentifier("project.createButton")
                    .accessibilityHint("Opens a sheet to name a new project.")
                }
            }
            .sheet(isPresented: $showingCreate) {
                NavigationStack {
                    Form {
                        TextField("Project title", text: $newProjectTitle)
                            .accessibilityIdentifier("project.create.titleField")
                            .accessibilityLabel("New project title")
                    }
                    .navigationTitle("New Project")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingCreate = false }
                                .accessibilityIdentifier("project.create.cancel")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Create") {
                                store.createProject(title: newProjectTitle)
                                newProjectTitle = ""
                                showingCreate = false
                            }
                            .accessibilityIdentifier("project.create.confirm")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete this project and its planning lists?",
                isPresented: deletionBinding($pendingDeletion),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let project = pendingDeletion {
                        runSafely { try store.deleteProject(project.id) }
                    }
                    pendingDeletion = nil
                }
                .accessibilityIdentifier("project.delete.confirm")
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("Take history in the local database is not removed.")
            }
            .errorAlert($errorMessage)
        }
    }

    private func toggleArchive(_ project: Project) {
        runSafely {
            try store.setProjectStatus(project.id, status: project.status == .archived ? .active : .archived)
        }
    }

    private func runSafely(_ work: () throws -> Void) {
        do { try work() } catch { errorMessage = error.localizedDescription }
    }

    private func deletionBinding<T>(
        _ value: Binding<T?>
    ) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.title)
                .font(.headline)
            HStack(spacing: 6) {
                Text(StatusGlyph.project(project.status))
                    .accessibilityHidden(true)
                Text(StatusCopy.project(project.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .accessibilityHidden(true)
                Text("\(project.sceneIDs.count) scenes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // One combined VoiceOver element: title then status then counts.
        .accessibilityElement(children: .combine)
        // Non-color status channel: glyph + text next to every color cue.
        .accessibilityLabel("\(project.title). \(StatusCopy.project(project.status))")
    }
}

/// Scene list for one project with reorder, status cycling, and delete.
struct SceneListView: View {
    @Environment(PlannerStore.self) private var store
    let project: Project

    @State private var showingAdd = false
    @State private var newSceneTitle = ""
    @State private var pendingDeletion: Scene?
    @State private var errorMessage: String?

    private var scenes: [Scene] { store.scenes(in: project.id) }

    var body: some View {
        List {
            if scenes.isEmpty {
                Text("No scenes yet. Add the first scene to start the plan.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sceneList.emptyState")
            }
            ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                NavigationLink(value: scene.id) {
                    SceneRow(scene: scene, shotCount: store.shots(in: scene.id).count)
                }
                .accessibilityIdentifier("sceneRow.index.\(index)")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDeletion = scene
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier("scene.delete.index.\(index)")
                }
                .swipeActions(edge: .leading) {
                    Button {
                        cycleSceneStatus(scene)
                    } label: {
                        Label("Cycle status", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .tint(.blue)
                    .accessibilityIdentifier("scene.cycleStatus.index.\(index)")
                }
            }
            .onMove { offsets, destination in
                runSafely {
                    try store.moveScenes(in: project.id, fromOffsets: offsets, toOffset: destination)
                }
            }
        }
        .navigationTitle(project.title)
        .navigationDestination(for: SceneID.self) { id in
            if store.scenes(in: project.id).contains(where: { $0.id == id }) {
                ShotListView(sceneID: id)
            } else {
                Text("This scene is no longer here.")
                    .accessibilityIdentifier("sceneDetail.gone")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Scene", systemImage: "plus")
                }
                .accessibilityIdentifier("scene.addButton")
                .accessibilityHint("Adds a new scene at the end of this project.")
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .accessibilityIdentifier("scene.reorderButton")
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                Form {
                    TextField("Scene title", text: $newSceneTitle)
                        .accessibilityIdentifier("scene.add.titleField")
                        .accessibilityLabel("New scene title")
                }
                .navigationTitle("New Scene")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAdd = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            runSafely {
                                try store.addScene(to: project.id, title: newSceneTitle)
                                newSceneTitle = ""
                                showingAdd = false
                            }
                        }
                        .accessibilityIdentifier("scene.add.confirm")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this scene and its shot list?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let scene = pendingDeletion {
                    runSafely { try store.deleteScene(scene.id) }
                }
                pendingDeletion = nil
            }
            .accessibilityIdentifier("scene.delete.confirm")
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        }
        .errorAlert($errorMessage)
    }

    /// Cycle planned -> active -> complete. Deleting or the shot-level
    /// controls stay explicit; cycling never destroys plan data.
    private func cycleSceneStatus(_ scene: Scene) {
        let next: SceneStatus
        switch scene.status {
        case .planned: next = .active
        case .active: next = .complete
        case .complete, .omitted, .unknown: next = .planned
        }
        runSafely { try store.setSceneStatus(scene.id, status: next) }
    }

    private func runSafely(_ work: () throws -> Void) {
        do { try work() } catch { errorMessage = error.localizedDescription }
    }
}

private struct SceneRow: View {
    let scene: Scene
    let shotCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scene.title)
                .font(.headline)
            HStack(spacing: 6) {
                Text(StatusGlyph.scene(scene.status))
                    .accessibilityHidden(true)
                Text(StatusCopy.scene(scene.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .accessibilityHidden(true)
                Text("\(shotCount) shots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(scene.title). \(StatusCopy.scene(scene.status)). \(shotCount) shots")
    }
}

/// Ordered shot list with move/insert, archive & omit controls, coverage
/// badges (glyph + text), and the shot editor sheet.
struct ShotListView: View {
    @Environment(PlannerStore.self) private var store
    let sceneID: SceneID

    @State private var showingAdd = false
    @State private var newShotTitle = ""
    @State private var editingShot: Shot?
    @State private var pendingDeletion: Shot?
    @State private var errorMessage: String?

    private var shots: [Shot] { store.shots(in: sceneID) }

    var body: some View {
        List {
            if shots.isEmpty {
                Text("No shots yet. Add the first shot to build this scene.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("shotList.emptyState")
            }
            ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                Button {
                    editingShot = shot
                } label: {
                    ShotRow(shot: shot, coverage: store.coverage(for: shot))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("shotRow.index.\(index)")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDeletion = shot
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier("shot.delete.index.\(index)")

                    Button {
                        cycleShotStatus(shot)
                    } label: {
                        Label("Status", systemImage: "circle.lefthalf.filled")
                    }
                    .tint(.blue)
                    .accessibilityIdentifier("shot.cycleStatus.index.\(index)")
                }
                .swipeActions(edge: .leading) {
                    Button {
                        setShotStatus(shot, .omitted)
                    } label: {
                        Label("Omit", systemImage: "minus.circle")
                    }
                    .tint(.orange)
                    .accessibilityIdentifier("shot.omit.index.\(index)")

                    Button {
                        setShotStatus(shot, .archived)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(.gray)
                    .accessibilityIdentifier("shot.archive.index.\(index)")
                }
            }
            .onMove { offsets, destination in
                runSafely {
                    try store.moveShots(in: sceneID, fromOffsets: offsets, toOffset: destination)
                }
            }
        }
        .navigationTitle("Shot list")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Shot", systemImage: "plus")
                }
                .accessibilityIdentifier("shot.addButton")
                .accessibilityHint("Adds a new shot at the end of this scene.")
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .accessibilityIdentifier("shot.reorderButton")
            }
        }
        // Shot is a value type with stable identity: sheet(item:) delivers a
        // snapshot copy of the row into the editor.
        .sheet(item: $editingShot) { shot in
            ShotEditorView(shot: shot)
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                Form {
                    TextField("Shot title", text: $newShotTitle)
                        .accessibilityIdentifier("shot.add.titleField")
                        .accessibilityLabel("New shot title")
                }
                .navigationTitle("New Shot")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAdd = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            runSafely {
                                try store.addShot(to: sceneID, title: newShotTitle)
                                newShotTitle = ""
                                showingAdd = false
                            }
                        }
                        .accessibilityIdentifier("shot.add.confirm")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this shot from the plan?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let shot = pendingDeletion {
                    runSafely { try store.deleteShot(shot.id) }
                }
                pendingDeletion = nil
            }
            .accessibilityIdentifier("shot.delete.confirm")
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        }
        .errorAlert($errorMessage)
    }

    private func setShotStatus(_ shot: Shot, _ status: ShotStatus) {
        runSafely { try store.setShotStatus(shot.id, status: status) }
    }

    private func cycleShotStatus(_ shot: Shot) {
        let next: ShotStatus
        switch shot.status {
        case .planned: next = .active
        case .active, .omitted, .archived, .unknown: next = .planned
        }
        setShotStatus(shot, next)
    }

    private func runSafely(_ work: () throws -> Void) {
        do { try work() } catch { errorMessage = error.localizedDescription }
    }
}

private struct ShotRow: View {
    let shot: Shot
    let coverage: CoverageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shot.title)
                .font(.headline)
            HStack(spacing: 6) {
                Text(StatusGlyph.shot(shot.status))
                    .accessibilityHidden(true)
                Text(StatusCopy.shot(shot.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .accessibilityHidden(true)
                Text(StatusGlyph.coverage(coverage.state))
                    .accessibilityHidden(true)
                Text(StatusCopy.coverage(coverage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !shot.framingTags.isEmpty {
                Text(shot.framingTags.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            shot.framingTags.isEmpty
                ? "\(shot.title). \(StatusCopy.shot(shot.status)). \(StatusCopy.coverage(coverage))"
                : "\(shot.title). \(StatusCopy.shot(shot.status)). \(StatusCopy.coverage(coverage)). Framing tags: \(shot.framingTags.joined(separator: ", "))."
        )
        .accessibilityHint("Opens the shot editor.")
    }
}

/// Shot editor: title, status, reusable framing tags, lens/orientation/
/// movement metadata, action notes, and reference metadata fields.
/// Optional fields keep explicit absence — "Not set" is a real state.
struct ShotEditorView: View {
    @Environment(PlannerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State var shot: Shot

    @State private var newTag = ""
    @State private var knownTags: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Shot title", text: $shot.title)
                        .accessibilityIdentifier("shotEditor.titleField")
                        .accessibilityLabel("Shot title")

                    Picker("Status", selection: Binding(
                        get: { shot.status },
                        set: { shot.status = $0 }
                    )) {
                        ForEach(ShotStatus.allCases, id: \.self) { status in
                            Text(statusDisplay(status)).tag(status)
                        }
                    }
                    .accessibilityIdentifier("shotEditor.statusPicker")
                }

                Section("Framing tags") {
                    ForEach(shot.framingTags, id: \.self) { tag in
                        HStack {
                            Text(tag)
                            Spacer()
                            Button {
                                shot.framingTags.removeAll { $0 == tag }
                            } label: {
                                Label("Remove tag \(tag)", systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("shotEditor.removeTag.\(tag)")
                        }
                    }
                    if !knownTags.isEmpty {
                        Menu {
                            ForEach(knownTags, id: \.self) { tag in
                                Button(tag) { addTag(tag) }
                            }
                        } label: {
                            Label("Reuse tag", systemImage: "tag")
                        }
                        .accessibilityIdentifier("shotEditor.reuseTagMenu")
                    }
                    HStack {
                        TextField("Add framing tag", text: $newTag)
                            .accessibilityIdentifier("shotEditor.tagField")
                            .accessibilityLabel("New framing tag")
                        Button("Add") {
                            addTag(newTag)
                            newTag = ""
                        }
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("shotEditor.tagAddButton")
                    }
                }

                Section("Framing metadata") {
                    TextField("Lens, for example 35mm prime", text: Binding(
                        get: { shot.lensDescription ?? "" },
                        set: { shot.lensDescription = $0.isEmpty ? nil : $0 }
                    ))
                    .accessibilityIdentifier("shotEditor.lensField")
                    .accessibilityLabel("Lens description")

                    Picker("Orientation", selection: Binding(
                        get: { shot.orientation },
                        set: { shot.orientation = $0 }
                    )) {
                        Text("Not set").tag(ShotOrientation?.none)
                        ForEach(ShotOrientation.allCases, id: \.self) { value in
                            Text(value.display).tag(ShotOrientation?.some(value))
                        }
                    }
                    .accessibilityIdentifier("shotEditor.orientationPicker")

                    Picker("Movement", selection: Binding(
                        get: { shot.movement },
                        set: { shot.movement = $0 }
                    )) {
                        Text("Not set").tag(ShotMovement?.none)
                        ForEach(ShotMovement.allCases, id: \.self) { value in
                            Text(value.display).tag(ShotMovement?.some(value))
                        }
                    }
                    .accessibilityIdentifier("shotEditor.movementPicker")
                }

                Section("Action notes") {
                    TextEditor(text: $shot.actionNotes)
                        .frame(minHeight: 88)
                        .accessibilityIdentifier("shotEditor.notesField")
                        .accessibilityLabel("Action notes")
                }

                Section("Reference metadata") {
                    TextField("Reference file name", text: Binding(
                        get: { shot.referenceFilename ?? "" },
                        set: { shot.referenceFilename = $0.isEmpty ? nil : $0 }
                    ))
                    .accessibilityIdentifier("shotEditor.referenceFileField")
                    .accessibilityLabel("Reference file name")
                    TextField("Reference caption", text: Binding(
                        get: { shot.referenceCaption ?? "" },
                        set: { shot.referenceCaption = $0.isEmpty ? nil : $0 }
                    ))
                    .accessibilityIdentifier("shotEditor.referenceCaptionField")
                    .accessibilityLabel("Reference caption")
                    Text("Reference stills live in the app container only when the shoot workspace saves them; this editor keeps the text metadata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit shot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("shotEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("shotEditor.save")
                }
            }
            .errorAlert($errorMessage)
            .onAppear(perform: loadKnownTags)
        }
    }

    private func loadKnownTags() {
        for project in store.projects
        where store.scenes(in: project.id).contains(where: { $0.id == shot.sceneID }) {
            knownTags = store.knownTags(in: project.id)
            break
        }
    }

    private func addTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !shot.framingTags.contains(trimmed) else { return }
        shot.framingTags.append(trimmed)
    }

    private func save() {
        do {
            try store.updateShot(shot)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func statusDisplay(_ status: ShotStatus) -> String {
        switch status {
        case .planned: return "Planned"
        case .active: return "Active"
        case .omitted: return "Omitted"
        case .archived: return "Archived"
        case .unknown: return "Unknown"
        }
    }
}

private extension ShotOrientation {
    var display: String {
        switch self {
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
        }
    }
}

private extension ShotMovement {
    var display: String {
        switch self {
        case .still: return "Still"
        case .panLeft: return "Pan left"
        case .panRight: return "Pan right"
        case .tiltUp: return "Tilt up"
        case .tiltDown: return "Tilt down"
        case .pushIn: return "Push in"
        case .pullOut: return "Pull out"
        case .handheld: return "Handheld"
        case .tracking: return "Tracking"
        case .crane: return "Crane"
        case .gimbal: return "Gimbal"
        }
    }
}

extension StatusGlyph {
    static func project(_ status: ProjectStatus) -> String {
        switch status {
        case .active: return "\u{25CF}"
        case .archived: return "\u{2193}"
        case .unknown: return "?"
        }
    }
}

extension StatusCopy {
    static func project(_ status: ProjectStatus) -> String {
        switch status {
        case .active: return "Project status: active"
        case .archived: return "Project status: archived"
        case .unknown: return "Project status: unknown"
        }
    }
}

/// Shared error alert so every planner surface reports validation
/// failures the same way instead of failing silently.
struct ErrorAlertModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(
            "Could not save",
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}

extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        modifier(ErrorAlertModifier(message: message))
    }
}
