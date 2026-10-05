import SwiftUI
import ShotDeckKit

/// Folded iPhone focus surface. The domain layout seam describes a future
/// unfolded arrangement; this view does not claim hardware detection.
struct ShootWorkspaceView: View {
    @Environment(PlannerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectID: ProjectID
    let sceneID: SceneID

    @State private var rating: TakeRating = .unreviewed
    @State private var notes = ""
    @State private var durationText = ""
    @State private var cameraText = ""
    @State private var checkLabel = ""
    @State private var errorMessage: String?

    private var shots: [Shot] { store.shots(in: sceneID) }
    private var context: ShootSessionContext { store.session(in: projectID) }
    private var current: Shot? {
        guard case let .active(id) = context else { return nil }
        return store.shot(id)
    }
    private var contextLabel: String {
        switch context {
        case .inactive: "No active shoot. Select a shot to begin."
        case .unresolved: "Shoot context unresolved. Select a shot explicitly."
        case .active: "Active shoot: \(current?.title ?? "Unavailable shot")"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(contextLabel)
                        .font(.headline)
                        .accessibilityIdentifier("shoot.context")

                    ForEach(shots) { shot in
                        Button("Shoot \(shot.title)") {
                            perform { try store.selectShot(shot.id, in: projectID) }
                        }
                        .disabled(shot.status == .omitted || shot.status == .archived)
                        .buttonStyle(.bordered)
                        .frame(minHeight: 54)
                        .accessibilityIdentifier("shoot.select.\(shot.id.rawValue.uuidString)")
                    }

                    if let shot = current {
                        Divider()
                        Text("Take ledger: \(shot.title)").font(.title3.bold())
                        Picker("Take rating", selection: $rating) {
                            Text("Unreviewed").tag(TakeRating.unreviewed)
                            Text("Keep").tag(TakeRating.keep)
                            Text("Reject").tag(TakeRating.reject)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("shoot.rating")
                        TextField("Take notes (optional)", text: $notes)
                            .accessibilityIdentifier("shoot.notes")
                        TextField("Duration in seconds (optional)", text: $durationText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("shoot.duration")
                        TextField("Camera or source (optional)", text: $cameraText)
                            .accessibilityIdentifier("shoot.camera")
                        Text("Duration and camera are never inferred; missing candidate facts keep coverage unknown.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Log take") {
                            perform {
                                let duration: Double?
                                if durationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    duration = nil
                                } else if let parsed = Double(durationText), parsed.isFinite, parsed > 0 {
                                    duration = parsed
                                } else {
                                    throw NSError(domain: "ShotDeck", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "Duration must be a positive number of seconds."])
                                }
                                try store.logTake(for: shot.id, in: projectID,
                                                  rating: rating, notes: notes,
                                                  durationSeconds: duration, cameraDescription: cameraText)
                                notes = ""
                                durationText = ""
                                cameraText = ""
                                rating = .unreviewed
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .accessibilityIdentifier("shoot.logTake")

                        if let ledger = try? store.ledger(for: shot.id) {
                            ForEach(Array(ledger.currentTakes.enumerated()), id: \.element.id) { index, take in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Take \(index + 1): \(take.rating.rawValue), \(take.notes.isEmpty ? "no notes" : take.notes)")
                                        .accessibilityIdentifier("shoot.take.\(index)")
                                    Button("Select take \(index + 1) as candidate") {
                                        perform { try store.chooseCandidate(take.id, for: shot.id, in: projectID) }
                                    }
                                    .accessibilityIdentifier("shoot.candidate.\(index)")
                                }
                            }
                            switch ledger.candidateSelection {
                            case .unresolved: Text("Candidate unresolved")
                            case .unknown: Text("Candidate unknown")
                            case .selected: Text("Candidate selected; review coverage reasons")
                            }
                        } else {
                            Text("Take ledger unavailable; status unknown")
                        }
                        let coverage = store.coverage(for: shot)
                        Text(StatusCopy.coverage(coverage))
                            .accessibilityIdentifier("shoot.coverage")
                        if !coverage.reasons.isEmpty {
                            Text("Coverage reasons: \(coverage.reasons.map(\.rawValue).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Divider()
                        Text("Continuity checklist").font(.title3.bold())
                        TextField("Required check label", text: $checkLabel)
                            .accessibilityIdentifier("shoot.checkLabel")
                        Button("Add required check") {
                            perform {
                                try store.addContinuity(to: shot.id, label: checkLabel)
                                checkLabel = ""
                            }
                        }
                        .disabled(checkLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("shoot.addCheck")
                        if let checks = try? store.continuity(for: shot.id) {
                            ForEach(checks) { check in
                                ContinuityCheckRow(check: check)
                            }
                        } else {
                            Text("Continuity unavailable; status unknown")
                        }
                    }
                    Button("End shoot") {
                        perform { try store.endSession(in: projectID) }
                    }
                    .disabled(context == .inactive)
                    .accessibilityIdentifier("shoot.end")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Shoot workspace")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("shoot.done")
                }
            }
            .errorAlert($errorMessage)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

private struct ContinuityCheckRow: View {
    @Environment(PlannerStore.self) private var store
    let check: ContinuityCheck
    @State private var notes = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(check.label): \(check.status.rawValue)")
                .accessibilityIdentifier("shoot.check.\(check.id.rawValue.uuidString)")
            TextField("Continuity notes", text: $notes)
                .accessibilityIdentifier("shoot.checkNotes.\(check.id.rawValue.uuidString)")
                .onAppear { notes = check.notes }
                .onSubmit { save(check.status) }
            HStack {
                Button("Matched") { save(.matched) }
                Button("Mismatch") { save(.mismatch) }
                Button("Unresolved") { save(.pending) }
            }
            .buttonStyle(.bordered)
        }
        .errorAlert($errorMessage)
    }

    private func save(_ status: ContinuityCheckStatus) {
        do { try store.setContinuity(check, status: status, notes: notes) }
        catch { errorMessage = error.localizedDescription }
    }
}
