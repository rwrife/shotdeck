import SwiftUI
import ShotDeckKit

/// Skeleton root view. The shot planner editor (issue #4) replaces this;
/// the shoot workspace arranges panes through `ShootWorkspaceLayout`
/// (issue #5).
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("ShotDeck")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Text(ShotDeckKit.milestone)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ContentView()
}
