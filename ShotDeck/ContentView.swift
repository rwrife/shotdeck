import SwiftUI
import ShotDeckKit

/// ShotDeck app root (issue #4): the planner flow — project list →
/// scene list → shot list/editor. The shoot workspace (issue #5)
/// will hang off the same document once take capture lands.
struct ContentView: View {
    var body: some View {
        ProjectListView()
    }
}

#Preview {
    ContentView()
        .environment(PlannerStore())
}
