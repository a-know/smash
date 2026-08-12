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
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
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
}

#Preview("Signed Out") {
    ContentView(
        appModel: AppModel(
            authenticationController: AppDependencies.makeAuthenticationController()
        )
    )
}
