import MarkdownDriveCore
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            ContentUnavailableView(
                "No Vault Selected",
                systemImage: "folder.badge.questionmark",
                description: Text(
                    "Choose a Google Drive folder to discover its \(MarkdownFileRules.requiredExtension) files."
                )
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            ContentUnavailableView(
                "No Document Open",
                systemImage: "doc.text",
                description: Text("Select a Markdown file from the sidebar to begin editing.")
            )
        }
        .navigationTitle("Markdown Drive")
        .frame(minWidth: 760, minHeight: 480)
    }
}

#Preview {
    ContentView()
}
