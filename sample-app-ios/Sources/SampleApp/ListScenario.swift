import SwiftUI
import ReticleKit

/// A long lazy list — the iOS twin of the Android sample's `ListScenarioActivity`.
/// SwiftUI's `List` only realizes the rows near the viewport, so `list.item40`
/// has no view, no accessibility element, and no frame until it is scrolled into
/// range: the selector is ABSENT, not merely off-screen.
///
/// The status line sits outside the list so a tap on a far-down row can be read
/// back without scrolling again.
struct ListScenarioView: View {
    @State private var status = "No row picked"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status)
                .font(.title3)
                .accessibilityIdentifier("list.status")

            List(0..<rowCount, id: \.self) { index in
                Button("Row \(index)") {
                    status = "Picked row \(index)"
                    Reticle.log("list_row_picked", metadata: ["index": .text(String(index))])
                }
                .accessibilityIdentifier("list.item\(index)")
            }
            .listStyle(.plain)
        }
        .padding(.horizontal, 16)
        .onAppear {
            Reticle.log("list_visible", metadata: ["rows": .text(String(rowCount))])
        }
    }

    private let rowCount = 60
}
