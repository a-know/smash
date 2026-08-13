import AppKit
import SwiftUI

struct MarkdownEditorCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .textEditing) {
            Button("Find…") {
                let sender = NSMenuItem()
                sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                NSApp.sendAction(
                    #selector(NSTextView.performFindPanelAction(_:)),
                    to: nil,
                    from: sender
                )
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}
