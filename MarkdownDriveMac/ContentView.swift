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
                    ContentUnavailableView(
                        vault.displayName,
                        systemImage: "folder",
                        description: Text("Markdown file discovery is the next implementation step.")
                    )
                } else {
                    ContentUnavailableView {
                        Label("No Vault Selected", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text(
                            "Choose a Google Drive folder to discover its \(MarkdownFileRules.requiredExtension) files."
                        )
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
            ContentUnavailableView(
                "No Document Open",
                systemImage: "doc.text",
                description: Text("Select a Markdown file from the sidebar to begin editing.")
            )
        }
        .frame(minWidth: 760, minHeight: 480)
        .sheet(isPresented: vaultBrowserPresentation) {
            VaultFolderBrowserView(appModel: appModel)
        }
        .toolbar {
            ToolbarItem {
                Button("Choose Vault", systemImage: "folder.badge.gearshape") {
                    Task {
                        await appModel.presentVaultBrowser()
                    }
                }
                .accessibilityLabel("Choose Google Drive Vault folder")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task {
                        await appModel.signOut()
                    }
                }
                .accessibilityLabel("Sign out of Google")
            }
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
