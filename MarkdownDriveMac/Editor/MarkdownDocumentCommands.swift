import SwiftUI

struct MarkdownDocumentCommands: Commands {
    @ObservedObject var appModel: AppModel

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                Task {
                    await appModel.saveDocument()
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!appModel.canSaveDocument)
        }
    }
}
