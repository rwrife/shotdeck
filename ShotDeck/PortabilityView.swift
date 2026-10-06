import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ShotDeckStore

/// Files sheets keep private data in memory until the user chooses a local
/// destination. No background transfer, account, or network code exists.
private struct PortableFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .pdf] }
    var bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}

struct PortabilityView: View {
    @Environment(PlannerStore.self) private var store
    @State private var file: PortableFile?
    @State private var type: UTType = .json
    @State private var filename = "ShotDeck Backup"
    @State private var showingSave = false
    @State private var showingImport = false
    @State private var preview: ImportPreview?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Your data") {
                Text("Projects, planning details, takes, continuity checks and session history are kept in this iPhone app's local SQLite database. ShotDeck has no account, analytics, cloud sync or upload path.")
                Text("No camera, microphone, photo library, contacts or location permission is requested. Reference filenames are text labels; the app does not copy or attach media files.")
            }
            Section("Backup and restore") {
                Text("Backups are unencrypted JSON. Anyone with the file can read project titles, notes, camera details and session history. Choose a trusted destination in Files and protect or delete copies yourself. Device backups may include the local database according to your iPhone settings.")
                Button("Save JSON backup") { prepareBackup() }
                    .accessibilityIdentifier("privacy.backup")
                Button("Choose JSON backup to restore") { showingImport = true }
                    .accessibilityIdentifier("privacy.restore")
                Text("Restore replaces every project and the complete take/session history. Preview the counts first; save a backup before replacing. This cannot be undone in the app.")
            }
            Section("Local reports") {
                Text("CSV is a readable report, not a restorable backup. It contains project and take details; spreadsheet formulas in user-entered text are escaped. PDF is a printable summary of coverage, not a backup.")
                Button("Save shot ledger CSV") { prepareCSV(\.shotsCSV, filename: "ShotDeck Shots") }
                    .accessibilityIdentifier("privacy.shotsCSV")
                Button("Save take ledger CSV") { prepareCSV(\.takesCSV, filename: "ShotDeck Takes") }
                    .accessibilityIdentifier("privacy.takesCSV")
                Button("Save coverage CSV") { prepareCSV(\.coverageCSV, filename: "ShotDeck Coverage") }
                    .accessibilityIdentifier("privacy.coverageCSV")
                Button("Save printable PDF") { preparePDF() }
                    .accessibilityIdentifier("privacy.pdf")
            }
        }
        .navigationTitle("Privacy & Files")
        .fileExporter(isPresented: $showingSave, document: file, contentType: type, defaultFilename: filename) { result in
            file = nil
            if case let .failure(error) = result { errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $showingImport, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let size = attrs[.size] as? NSNumber,
                      size.int64Value <= 25_000_000 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                preview = ImportPreview(archive: try BackupArchive.decode(Data(contentsOf: url)))
            } catch { errorMessage = error.localizedDescription }
        }
        .sheet(item: $preview) { item in
            NavigationStack {
                Form {
                    Text("This backup contains \(item.archive.projects.count) projects, \(item.archive.scenes.count) scenes, \(item.archive.shots.count) shots, \(item.archive.takeCount) takes, \(item.archive.continuityChecks.count) continuity checks and \(item.archive.sessionEvents.count) session events.")
                    Text("It will replace ALL existing data on this iPhone. Save a backup of your current data first. This action cannot be undone.")
                }
                .navigationTitle("Preview restore")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { preview = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Replace all data", role: .destructive) {
                            do { try store.restoreFromArchive(item.archive); preview = nil }
                            catch { errorMessage = error.localizedDescription }
                        }
                        .accessibilityIdentifier("privacy.replace")
                    }
                }
            }
        }
        .alert("File operation failed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func prepareBackup() {
        do { prepare(try store.backupArchive().data(), type: .json, filename: "ShotDeck Backup") }
        catch { errorMessage = error.localizedDescription }
    }

    private func prepareCSV(_ value: KeyPath<ReportBundle, String>, filename: String) {
        do { try prepare(Data(store.reportBundle()[keyPath: value].utf8),
                         type: .commaSeparatedText, filename: filename) }
        catch { errorMessage = error.localizedDescription }
    }

    private func preparePDF() {
        do {
            let lines = try store.reportBundle().printLines
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let bytes = renderer.pdfData { context in
                var y: CGFloat = 792
                let style: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
                for line in lines {
                    let paragraph = line as NSString
                    let height = min(690, ceil(paragraph.boundingRect(
                        with: CGSize(width: 520, height: 690),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: style, context: nil).height) + 8)
                    if y + height > 752 {
                        context.beginPage()
                        y = 40
                    }
                    paragraph.draw(in: CGRect(x: 46, y: y, width: 520, height: height), withAttributes: style)
                    y += height
                }
            }
            prepare(bytes, type: .pdf, filename: "ShotDeck Coverage")
        } catch { errorMessage = error.localizedDescription }
    }

    private func prepare(_ data: Data, type: UTType, filename: String) {
        self.file = PortableFile(bytes: data)
        self.type = type
        self.filename = filename
        showingSave = true
    }
}

private struct ImportPreview: Identifiable {
    let id = UUID()
    let archive: BackupArchive
}
