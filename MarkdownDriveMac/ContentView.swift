import MarkdownDriveCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Group {
            switch appModel.authenticationState {
            case .signedOut:
                AuthenticationView(appModel: appModel)
            case .restoring:
                ProgressView("Restoring your Google session…")
                    .frame(minWidth: 520, minHeight: 360)
            case .signingIn:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Complete authorization in your browser.")
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 520, minHeight: 360)
            case .signedIn:
                VaultPlaceholderView(appModel: appModel)
            case .failed(let error):
                AuthenticationView(appModel: appModel, error: error)
            }
        }
        .navigationTitle("Markdown Drive")
    }
}

private struct AuthenticationView: View {
    @ObservedObject var appModel: AppModel
    let error: AuthenticationError?

    init(appModel: AppModel, error: AuthenticationError? = nil) {
        self.appModel = appModel
        self.error = error
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.icloud")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Connect Google Drive")
                    .font(.title2.bold())
                Text("Markdown Drive edits ordinary Markdown files directly in a Drive folder you choose.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            if let error {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .accessibilityLabel("Authentication error: \(error.localizedDescription)")
            }

            Button("Sign in with Google") {
                Task {
                    await appModel.signIn()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("For stronger isolation, you can use a dedicated Google account that only owns or accesses the Vault.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(40)
        .frame(minWidth: 600, minHeight: 440)
    }
}

private struct VaultPlaceholderView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        NavigationSplitView {
            Group {
                if let vault = appModel.selectedVault {
                    VaultSidebar(appModel: appModel, vault: vault)
                } else {
                    ContentUnavailableView {
                        Label("No Vault Selected", systemImage: "folder.badge.questionmark")
                    } description: {
                        if let error = appModel.vaultPersistenceError {
                            Text(error)
                        } else {
                            Text(
                                "Choose a Google Drive folder to discover its \(MarkdownFileRules.requiredExtension) files."
                            )
                        }
                    } actions: {
                        Button("Choose Vault…") {
                            Task {
                                await appModel.presentVaultBrowser()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            MarkdownEditorDetail(appModel: appModel)
        }
        .frame(minWidth: 760, minHeight: 480)
        .sheet(isPresented: vaultBrowserPresentation) {
            VaultFolderBrowserView(appModel: appModel)
        }
        .sheet(isPresented: conflictAlert) {
            ConflictResolutionView(appModel: appModel)
        }
        .sheet(isPresented: newNotePresentation) {
            NewNoteView(appModel: appModel)
        }
        .sheet(isPresented: newFolderPresentation) {
            NewFolderView(appModel: appModel)
        }
        .sheet(isPresented: renamePresentation) {
            RenameItemView(appModel: appModel)
        }
        .toolbar {
            ToolbarItem {
                Button("New Note", systemImage: "square.and.pencil") {
                    appModel.presentNewNote()
                }
                .disabled(!appModel.canCreateVaultItems)
                .accessibilityLabel("Create Markdown note")
            }
            ToolbarItem {
                Button("New Folder", systemImage: "folder.badge.plus") {
                    appModel.presentNewFolder()
                }
                .disabled(!appModel.canCreateVaultItems)
                .accessibilityLabel("Create folder in the selected Vault folder")
            }
            ToolbarItem {
                Button("Rename", systemImage: "pencil") {
                    appModel.presentRenameSelectedItem()
                }
                .disabled(!appModel.canRenameSelectedItem)
                .accessibilityLabel("Rename selected Vault item")
            }
            ToolbarItem {
                Button("Save", systemImage: "square.and.arrow.down") {
                    Task {
                        await appModel.saveDocument()
                    }
                }
                .disabled(!appModel.canSaveDocument)
                .accessibilityLabel("Save Markdown document")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await appModel.loadVaultTree()
                    }
                }
                .disabled(appModel.selectedVault == nil)
                .accessibilityLabel("Refresh Vault contents")
            }
            ToolbarItem {
                Button("Choose Vault", systemImage: "folder.badge.gearshape") {
                    Task {
                        await appModel.presentVaultBrowser()
                    }
                }
                .disabled(appModel.hasDirtyDocument)
                .help("Save or discard the current edits before changing Vaults.")
                .accessibilityLabel("Choose Google Drive Vault folder")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task {
                        await appModel.signOut()
                    }
                }
                .disabled(appModel.hasDirtyDocument)
                .help("Save or discard the current edits before signing out.")
                .accessibilityLabel("Sign out of Google")
            }
        }
        .alert(saveAlertTitle, isPresented: saveErrorAlert) {
            Button("OK", role: .cancel) {
                appModel.dismissSaveErrorAlert()
            }
        } message: {
            Text(saveErrorMessage)
        }
    }

    private var vaultBrowserPresentation: Binding<Bool> {
        Binding(
            get: { appModel.isVaultBrowserPresented },
            set: { isPresented in
                if !isPresented {
                    appModel.dismissVaultBrowser()
                }
            }
        )
    }

    private var conflictAlert: Binding<Bool> {
        Binding(
            get: { appModel.isConflictAlertPresented },
            set: { isPresented in
                if !isPresented {
                    appModel.dismissConflictAlert()
                }
            }
        )
    }

    private var newNotePresentation: Binding<Bool> {
        Binding(
            get: { appModel.isNewNotePresented },
            set: { isPresented in
                if !isPresented {
                    appModel.dismissItemCreation()
                }
            }
        )
    }

    private var newFolderPresentation: Binding<Bool> {
        Binding(
            get: { appModel.isNewFolderPresented },
            set: { isPresented in
                if !isPresented {
                    appModel.dismissItemCreation()
                }
            }
        )
    }

    private var renamePresentation: Binding<Bool> {
        Binding(
            get: { appModel.isRenamePresented },
            set: { isPresented in
                if !isPresented {
                    appModel.dismissRename()
                }
            }
        )
    }

    private var saveErrorAlert: Binding<Bool> {
        Binding(
            get: { appModel.isSaveErrorAlertPresented },
            set: { isPresented in
                if !isPresented {
                    appModel.dismissSaveErrorAlert()
                }
            }
        )
    }

    private var saveErrorMessage: String {
        switch appModel.documentSaveState {
        case .failed(let message), .reloadFailed(let message), .statusUnknown(let message):
            message
        default:
            "The document could not be saved. Your local edits are still available."
        }
    }

    private var saveAlertTitle: String {
        if case .reloadFailed = appModel.documentSaveState {
            return "Reload Failed"
        }
        if case .statusUnknown = appModel.documentSaveState {
            return "Save Status Unknown"
        }
        return "Save Failed"
    }
}

private struct RenameItemView: View {
    @ObservedObject var appModel: AppModel
    @State private var name = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .focused($isNameFocused)

            renameStatus

            HStack {
                Button("Cancel", role: .cancel) {
                    appModel.dismissRename()
                }
                Spacer()
                Button("Rename") {
                    Task {
                        await appModel.renameTarget(to: name)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
        .interactiveDismissDisabled(appModel.vaultItemRenameState == .renaming)
        .onAppear {
            guard let item = appModel.renameTargetItem else {
                return
            }
            name =
                item.kind == .file
                ? (item.name as NSString).deletingPathExtension
                : item.name
            isNameFocused = true
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && appModel.vaultItemRenameState != .renaming
            && !hasUnknownStatus
    }

    private var hasUnknownStatus: Bool {
        if case .statusUnknown = appModel.vaultItemRenameState {
            return true
        }
        return false
    }

    @ViewBuilder
    private var renameStatus: some View {
        switch appModel.vaultItemRenameState {
        case .renaming:
            ProgressView("Renaming in Google Drive…")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .statusUnknown(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Close this dialog and refresh the Vault before trying again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .idle:
            EmptyView()
        }
    }
}

private struct NewNoteView: View {
    @ObservedObject var appModel: AppModel
    @State private var name = "Untitled"
    @State private var parentFolderID = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .focused($isNameFocused)

            Picker("Location", selection: $parentFolderID) {
                ForEach(appModel.availableVaultFolders) { folder in
                    Text(folder.displayPath).tag(folder.id)
                }
            }

            creationError

            HStack {
                Button("Cancel", role: .cancel) {
                    appModel.dismissItemCreation()
                }
                Spacer()
                Button("Create") {
                    Task {
                        await appModel.createNewNote(
                            name: name,
                            parentFolderID: parentFolderID
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
        .interactiveDismissDisabled(appModel.vaultItemCreationState == .creating)
        .onAppear {
            parentFolderID = appModel.defaultCreationFolderID ?? ""
            isNameFocused = true
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !parentFolderID.isEmpty
            && appModel.vaultItemCreationState != .creating
            && !hasUnknownStatus
    }

    private var hasUnknownStatus: Bool {
        if case .statusUnknown = appModel.vaultItemCreationState {
            return true
        }
        return false
    }

    @ViewBuilder
    private var creationError: some View {
        switch appModel.vaultItemCreationState {
        case .creating:
            ProgressView("Creating in Google Drive…")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .statusUnknown(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Close this dialog and refresh the Vault before trying again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .idle:
            EmptyView()
        }
    }
}

private struct NewFolderView: View {
    @ObservedObject var appModel: AppModel
    @State private var name = "New Folder"
    @State private var parentFolderID = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .focused($isNameFocused)

            LabeledContent("Location", value: destinationName)

            creationError

            HStack {
                Button("Cancel", role: .cancel) {
                    appModel.dismissItemCreation()
                }
                Spacer()
                Button("Create") {
                    Task {
                        await appModel.createNewFolder(
                            name: name,
                            parentFolderID: parentFolderID
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
        .interactiveDismissDisabled(appModel.vaultItemCreationState == .creating)
        .onAppear {
            parentFolderID = appModel.defaultCreationFolderID ?? ""
            isNameFocused = true
        }
    }

    private var destinationName: String {
        appModel.availableVaultFolders.first { $0.id == parentFolderID }?.displayPath ?? "Vault"
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !parentFolderID.isEmpty
            && appModel.vaultItemCreationState != .creating
            && !hasUnknownStatus
    }

    private var hasUnknownStatus: Bool {
        if case .statusUnknown = appModel.vaultItemCreationState {
            return true
        }
        return false
    }

    @ViewBuilder
    private var creationError: some View {
        switch appModel.vaultItemCreationState {
        case .creating:
            ProgressView("Creating in Google Drive…")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .statusUnknown(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Close this dialog and refresh the Vault before trying again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .idle:
            EmptyView()
        }
    }
}

private struct ConflictResolutionView: View {
    @ObservedObject var appModel: AppModel
    @State private var isConfirmingOverwrite = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(isConfirmingOverwrite ? "Overwrite Remote Changes?" : "Remote Changes Detected")
                    .font(.title2.bold())
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            if isConfirmingOverwrite {
                overwriteButtons
            } else {
                resolutionButtons
            }
        }
        .padding(28)
        .frame(width: 640)
        .interactiveDismissDisabled()
    }

    private var message: String {
        if isConfirmingOverwrite {
            return "This permanently replaces the newer Google Drive content with the text currently in this editor."
        }
        return
            "This file was changed on another device. Reloading will discard the unsaved text currently in the editor."
    }

    private var resolutionButtons: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                appModel.dismissConflictAlert()
            }
            Spacer()
            Button("Reload Remote Version", role: .destructive) {
                Task {
                    await appModel.reloadRemoteDocumentAfterConflict()
                }
            }
            Button("Save a Copy") {
                Task {
                    await appModel.saveConflictCopy()
                }
            }
            Button("Overwrite Anyway", role: .destructive) {
                isConfirmingOverwrite = true
            }
        }
    }

    private var overwriteButtons: some View {
        HStack {
            Button("Back", role: .cancel) {
                isConfirmingOverwrite = false
            }
            Spacer()
            Button("Overwrite Remote File", role: .destructive) {
                Task {
                    await appModel.overwriteConflictingDocument()
                }
            }
        }
    }
}

private struct VaultSidebar: View {
    @ObservedObject var appModel: AppModel
    let vault: Vault

    var body: some View {
        Group {
            switch appModel.vaultTreeState {
            case .idle, .loading:
                ProgressView("Loading \(vault.displayName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could Not Load Vault", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        Task {
                            await appModel.loadVaultTree()
                        }
                    }
                }
            case .loaded(let tree):
                if tree.root.children.isEmpty {
                    ContentUnavailableView {
                        Label("Vault Is Empty", systemImage: "folder")
                    } description: {
                        Text("No Markdown files or subfolders were found in this Vault.")
                    } actions: {
                        Button("Refresh") {
                            Task {
                                await appModel.loadVaultTree()
                            }
                        }
                    }
                } else {
                    List(selection: treeSelection) {
                        VaultTreeNodeRow(node: tree.root, appModel: appModel)
                    }
                    .accessibilityLabel("Vault files and folders")
                }
            }
        }
        .navigationTitle(vault.displayName)
        .alert("Discard unsaved changes?", isPresented: discardConfirmation) {
            Button("Cancel", role: .cancel) {
                appModel.cancelPendingDocumentOpen()
            }
            Button("Discard and Open", role: .destructive) {
                Task {
                    await appModel.confirmDiscardAndOpenPendingDocument()
                }
            }
        } message: {
            Text("The current document has edits that have not been saved to Google Drive.")
        }
    }

    private var treeSelection: Binding<String?> {
        Binding(
            get: { appModel.selectedTreeItemID },
            set: { id in
                Task {
                    await appModel.selectTreeItem(id: id)
                }
            }
        )
    }

    private var discardConfirmation: Binding<Bool> {
        Binding(
            get: { appModel.isDiscardConfirmationPresented },
            set: { appModel.setDiscardConfirmationPresented($0) }
        )
    }
}

private struct VaultTreeNodeRow: View {
    let node: DriveTreeNode
    @ObservedObject var appModel: AppModel

    var body: some View {
        if node.item.kind == .folder {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(node.children) { child in
                    VaultTreeNodeRow(node: child, appModel: appModel)
                }
            } label: {
                Label(node.item.name, systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .contextMenu {
                        renameButton
                    }
            }
            .tag(node.item.id)
        } else {
            Label(node.item.name, systemImage: "doc.text")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .tag(node.item.id)
                .contextMenu {
                    renameButton
                }
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { appModel.expandedFolderIDs.contains(node.item.id) },
            set: { appModel.setFolderExpanded(id: node.item.id, isExpanded: $0) }
        )
    }

    private var renameButton: some View {
        Button("Rename…") {
            appModel.presentRename(itemID: node.item.id)
        }
        .disabled(!appModel.canRenameItem(id: node.item.id))
    }
}

private struct MarkdownEditorDetail: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Group {
            switch appModel.documentState {
            case .idle:
                ContentUnavailableView(
                    "No Document Open",
                    systemImage: "doc.text",
                    description: Text("Select a Markdown file from the sidebar to begin editing.")
                )
            case .loading:
                ProgressView("Opening Markdown file…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(_, let message):
                ContentUnavailableView {
                    Label("Could Not Open Document", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        Task {
                            await appModel.retryDocumentLoad()
                        }
                    }
                }
            case .loaded(let document):
                VStack(spacing: 0) {
                    HStack {
                        Text(document.name)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        if document.isDirty {
                            Label(saveStatusText, systemImage: saveStatusSymbol)
                                .font(.caption)
                                .foregroundStyle(saveStatusColor)
                        } else {
                            if appModel.documentSaveState == .saved {
                                Label("Saved", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Loaded from Google Drive")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider()

                    NativeMarkdownEditor(text: documentText)
                        .accessibilityLabel("Markdown source editor")
                }
                .navigationTitle(document.isDirty ? "\(document.name) — Edited" : document.name)
            }
        }
    }

    private var documentText: Binding<String> {
        Binding(
            get: {
                guard case .loaded(let document) = appModel.documentState else {
                    return ""
                }
                return document.text
            },
            set: { appModel.updateDocumentText($0) }
        )
    }

    private var saveStatusText: String {
        switch appModel.documentSaveState {
        case .saving:
            "Saving…"
        case .failed:
            "Save failed"
        case .conflict:
            "Remote changes detected"
        case .reloadFailed:
            "Reload failed"
        case .statusUnknown:
            "Save status unknown"
        case .idle, .saved:
            "Edited"
        }
    }

    private var saveStatusSymbol: String {
        switch appModel.documentSaveState {
        case .saving:
            "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed, .reloadFailed, .statusUnknown:
            "exclamationmark.triangle.fill"
        case .conflict:
            "arrow.trianglehead.branch"
        case .idle, .saved:
            "circle.fill"
        }
    }

    private var saveStatusColor: Color {
        switch appModel.documentSaveState {
        case .failed, .conflict, .reloadFailed, .statusUnknown:
            .orange
        case .idle, .saving, .saved:
            .secondary
        }
    }
}

private struct VaultFolderBrowserView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            browserContent
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 520)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Button("Back", systemImage: "chevron.left") {
                Task {
                    await appModel.navigateBack()
                }
            }
            .disabled(!canNavigateBack)

            Text(currentPath)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Reload", systemImage: "arrow.clockwise") {
                Task {
                    await appModel.loadMyDrive()
                }
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Reload My Drive folders")
        }
        .padding()
    }

    @ViewBuilder
    private var browserContent: some View {
        switch appModel.vaultBrowserState {
        case .idle, .loading:
            ProgressView("Loading Google Drive folders…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Could Not Load Folders", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task {
                        await appModel.loadMyDrive()
                    }
                }
            }
        case .loaded(let snapshot):
            if snapshot.childFolders.isEmpty {
                ContentUnavailableView(
                    "No Subfolders",
                    systemImage: "folder",
                    description: Text("You can use the current folder as the Vault.")
                )
            } else {
                List(snapshot.childFolders, id: \.id) { folder in
                    Button {
                        Task {
                            await appModel.openFolder(id: folder.id)
                        }
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open folder \(folder.name)")
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                appModel.dismissVaultBrowser()
            }
            Spacer()
            Button("Use This Folder") {
                Task {
                    await appModel.selectCurrentFolderAsVault()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(currentFolder == nil)
        }
        .padding()
    }

    private var currentSnapshot: DriveFolderBrowserSnapshot? {
        guard case .loaded(let snapshot) = appModel.vaultBrowserState else {
            return nil
        }
        return snapshot
    }

    private var currentFolder: DriveItem? {
        currentSnapshot?.currentFolder
    }

    private var canNavigateBack: Bool {
        currentSnapshot?.canNavigateBack == true
    }

    private var currentPath: String {
        currentSnapshot?.path.map(\.name).joined(separator: " / ") ?? "My Drive"
    }
}

#Preview("Signed Out") {
    ContentView(appModel: AppDependencies.makeAppModel())
}
