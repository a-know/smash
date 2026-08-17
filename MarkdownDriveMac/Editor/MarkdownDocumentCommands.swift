import SwiftUI

struct MarkdownDocumentCommands: Commands {
    @ObservedObject var appModel: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                appModel.presentNewNote()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!appModel.canCreateVaultItems)

            Button("New Folder") {
                appModel.presentNewFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!appModel.canCreateVaultItems)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                Task {
                    await appModel.saveDocument()
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!appModel.canSaveDocument)
        }

        CommandGroup(after: .saveItem) {
            Button("Refresh Vault") {
                Task {
                    await appModel.loadVaultTree()
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(appModel.selectedVault == nil)
        }

        CommandMenu("Item") {
            Button("Rename…") {
                appModel.presentRenameSelectedItem()
            }
            .disabled(!appModel.canRenameSelectedItem)

            Divider()

            Button("Move to Trash") {
                appModel.presentTrashSelectedItem()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!appModel.canTrashSelectedItem)
        }
    }
}
