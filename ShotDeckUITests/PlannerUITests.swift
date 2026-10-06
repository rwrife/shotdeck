import XCTest

/// Planner journeys (issue #4) against the real app, exercising the
/// accessibility identifiers and non-color status labels VoiceOver users
/// depend on. Run on the pinned Apple toolchain in CI.
final class PlannerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // `PlannerStore` gives every `--ui-tests` launch a fresh temp
        // database, so journeys always start from an honest empty state.
        app.launchArguments = ["--ui-tests"]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// Resolve by accessibilityIdentifier across any element class —
    /// SwiftUI surfaces TextFields/TextEditors/Pickers differently per
    /// container, but the identifier always rides on the element itself.
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func expectElement(_ id: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(id)
        if !target.waitForExistence(timeout: timeout) {
            XCTFail("Missing element '\(id)'. Reachable ids: \(reachableIds())", file: file, line: line)
        }
    }

    private func expectStatusText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        let match = app.descendants(matching: .any).matching(predicate).firstMatch
        if !match.waitForExistence(timeout: 5) {
            XCTFail("Missing status text '\(text)'. Reachable ids: \(reachableIds())", file: file, line: line)
        }
    }

    /// One-shot diagnostic provenance on failure (kept cheap, used only in
    /// failure paths): identifiers that exist in the current tree.
    private func reachableIds() -> String {
        app.descendants(matching: .any).allElementsBoundByIndex.prefix(200)
            // Closure, not key path: `identifier` is MainActor-isolated and
            // key paths to it can't be formed here under Swift 6.
            .map { $0.identifier }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        expectElement(id, file: file, line: line)
        element(id).tap()
    }

    private func type(_ id: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        expectElement(id, file: file, line: line)
        let field = element(id)
        field.tap()
        field.typeText(text)
    }

    func testPlannerJourney() throws {
        // 1. Empty state + project creation.
        expectElement("projectList.emptyState")
        tap("project.createButton")
        type("project.create.titleField", "Journey Project")
        tap("project.create.confirm")

        // 2. Project row shows non-color-only status text.
        expectElement("projectRow.index.0")
        expectStatusText("Project status: active")
        tap("projectRow.index.0")

        // 3. Scene creation with trimmed title.
        expectElement("sceneList.emptyState")
        tap("scene.addButton")
        type("scene.add.titleField", "Lobby")
        tap("scene.add.confirm")
        expectElement("sceneRow.index.0")
        expectStatusText("Scene status: planned")
        tap("sceneRow.index.0")

        // 4. Shot creation + unknown-safe coverage badge.
        expectElement("shotList.emptyState")
        tap("shot.addButton")
        type("shot.add.titleField", "Wide establishing")
        tap("shot.add.confirm")
        expectElement("shotRow.index.0")
        // With the real empty ledger available, this is explicitly not started.
        expectStatusText("Coverage: not started")

        // 5. Editor: tag, lens, orientation, notes.
        tap("shotRow.index.0")
        expectElement("shotEditor.titleField")
        type("shotEditor.tagField", "wide")
        tap("shotEditor.tagAddButton")
        type("shotEditor.lensField", "35mm prime")
        tap("shotEditor.orientationPicker")
        let orientationOption = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Portrait")).firstMatch
        XCTAssertTrue(
            orientationOption.waitForExistence(timeout: 5),
            "Portrait option missing. Reachable ids: \(reachableIds())"
        )
        orientationOption.tap()
        type("shotEditor.notesField", "Talent enters left")
        tap("shotEditor.save")

        // The tag now shows on the shot row.
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "wide")).firstMatch
                .waitForExistence(timeout: 5),
            "tag missing on row. Reachable ids: \(reachableIds())"
        )

        // 6. Swipe status cycle -> active.
        element("shotRow.index.0").swipeLeft()
        tap("shot.cycleStatus.index.0")
        expectStatusText("Shot status: active")

        // 7. Omit via leading swipe; coverage follows to omitted.
        element("shotRow.index.0").swipeRight()
        tap("shot.omit.index.0")
        expectStatusText("Shot status: omitted")
        expectStatusText("Coverage: omitted")

        // 8. Delete with confirmation dialog.
        element("shotRow.index.0").swipeLeft()
        tap("shot.delete.index.0")
        tap("shot.delete.confirm")
        expectElement("shotList.emptyState")
    }

    func testShootJourneyRestoresSessionAndKeepsMissingFactsUnknown() throws {
        let token = UUID().uuidString
        app.terminate()
        app.launchArguments = ["--ui-tests", "--ui-tests-persist", token]
        app.launch()
        tap("project.createButton")
        type("project.create.titleField", "Shoot Project")
        tap("project.create.confirm")
        tap("projectRow.index.0")
        tap("scene.addButton")
        type("scene.add.titleField", "Exterior")
        tap("scene.add.confirm")
        tap("sceneRow.index.0")
        tap("shot.addButton")
        type("shot.add.titleField", "Arrival")
        tap("shot.add.confirm")
        tap("shoot.open")
        XCTAssertTrue(element("shoot.context").label.contains("No active shoot"))
        let select = app.buttons.matching(NSPredicate(format: "label == %@", "Shoot Arrival")).firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        XCTAssertTrue(element("shoot.context").label.contains("Active shoot: Arrival"))
        tap("shoot.logTake")
        expectElement("shoot.take.0")
        expectStatusText("Candidate unresolved")
        XCTAssertTrue(element("shoot.coverage").label.contains("attempted"))
        tap("shoot.candidate.0")
        // Candidate cannot become green: duration and camera were not entered.
        XCTAssertTrue(element("shoot.coverage").label.contains("unknown"))
        type("shoot.checkLabel", "Wardrobe")
        tap("shoot.addCheck")
        expectStatusText("Wardrobe: pending")
        tap("shoot.done")

        app.terminate()
        app.launch()
        tap("projectRow.index.0")
        tap("sceneRow.index.0")
        tap("shoot.open")
        XCTAssertTrue(element("shoot.context").label.contains("Active shoot: Arrival"))
        expectElement("shoot.take.0")
        expectStatusText("Wardrobe: pending")
        XCTAssertTrue(element("shoot.coverage").label.contains("unknown"))
    }

    func testPrivacyAndPortabilityViewSurfacesOptions() throws {
        tap("project.privacyFiles")
        expectStatusText("Your data")
        expectStatusText("Backup and restore")
        expectElement("privacy.backup")
        expectElement("privacy.restore")
        // Form rows below the privacy copy are lazy; reveal the report section.
        let pdf = element("privacy.pdf")
        for _ in 0..<6 where !pdf.exists || !pdf.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        expectStatusText("Local reports")
        expectElement("privacy.shotsCSV")
        expectElement("privacy.takesCSV")
        expectElement("privacy.coverageCSV")
        expectElement("privacy.pdf")
    }
}
