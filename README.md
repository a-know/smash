# Markdown Drive

Markdown Drive is a focused macOS Markdown source editor backed directly by a folder in Google
Drive. Google Drive remains the source of truth: notes stay as ordinary `.md` files, and Google
Drive for desktop is not required.

The current MVP targets macOS 15 or later. Its shared `MarkdownDriveCore` Swift package contains
the platform-neutral Drive, Vault, document, and conflict-safety logic intended for later iPadOS and
iOS applications.

## Current capabilities

- Sign in through a Google Desktop OAuth client and securely retain the refresh credential in
  Keychain.
- Choose and restore one Google Drive folder as the Vault.
- Recursively browse existing Markdown files without registering them individually.
- Open and edit UTF-8 Markdown with native macOS editing, Japanese IME, undo/redo, and find.
- Safely save to the same Drive file with remote-change detection and explicit conflict choices.
- Create and rename notes and folders.
- Move owned items to Google Drive Trash.
- Recoverably move editable items that cannot be trashed into the Vault-local `_SMASH_TRASH`
  control folder.

## Prerequisites

- macOS 15 or later
- Xcode 16.4 or later with Swift 6.1 support
- A Google Cloud project with the Google Drive API enabled
- A Google OAuth client whose application type is **Desktop app**
- A Google account added as a test user while the OAuth consent screen is in Testing status

The app requests the restricted `https://www.googleapis.com/auth/drive` scope because it must
enumerate and edit files that already exist below the selected Vault. See
[`docs/OAUTH.md`](docs/OAUTH.md) for the scope rationale, security model, and publication
requirements.

## Configure Google OAuth

1. In Google Cloud Console, enable Google Drive API.
2. Configure the Google Auth Platform consent screen and declare the Drive scope above.
3. If the app is in Testing status, add every Google account that will sign in as a test user.
4. Create a **Desktop app** OAuth client and copy its client ID and client secret.
5. Create the ignored local build configuration:

   ```sh
   cp Config/OAuth.local.xcconfig.example Config/OAuth.local.xcconfig
   ```

6. Set both values in `Config/OAuth.local.xcconfig`:

   ```text
   GOOGLE_OAUTH_CLIENT_ID = your client ID
   GOOGLE_OAUTH_CLIENT_SECRET = your client secret
   ```

Do not commit this file, OAuth client JSON, tokens, or exported Keychain data. A native app cannot
keep a distributed client secret confidential; PKCE protects the authorization-code exchange, and
the app enforces the selected Vault boundary independently of the OAuth grant.

## Run the app

1. Open `MarkdownDrive.xcodeproj` in Xcode.
2. Select your own Development Team under **Signing & Capabilities** when the repository owner's
   team is unavailable.
3. Choose the `MarkdownDriveMac` scheme and **My Mac** destination.
4. Run the app.
5. Sign in with a configured Google test user.
6. Choose a Drive folder as the Vault.

The folder choice is restored at the next launch. Normal app operations remain restricted to that
Vault even though the OAuth scope grants broader Drive access.

## Keyboard commands

| Command | Shortcut |
| --- | --- |
| New note | `⌘N` |
| New folder | `⇧⌘N` |
| Save | `⌘S` |
| Find in the current document | `⌘F` |
| Refresh Vault | `⌘R` |
| Move selected item to Trash | `⌘⌫` |

## Tests

Run the shared-core tests:

```sh
xcrun swift test --package-path Packages/MarkdownDriveCore
```

Run the macOS tests and build without code signing:

```sh
xcodebuild \
  -project MarkdownDrive.xcodeproj \
  -scheme MarkdownDriveMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/XcodeDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

CI also enforces Swift formatting. The manual real-account checks are documented in
[`docs/ACCEPTANCE.md`](docs/ACCEPTANCE.md).

## Known limitations

- The MVP supports one Vault and one open document at a time.
- Refresh is manual; there is no realtime or periodic Drive synchronization.
- Offline-first editing and a local filesystem mirror are not implemented.
- Markdown preview, syntax highlighting, attachments, tags, backlinks, and full-text body search
  are outside the MVP.
- `_SMASH_TRASH` is an application-level recovery folder, not Google Drive Trash. Moving an item out
  of it makes the item active again after refresh.
- External OAuth apps using the Drive scope require Google verification for public distribution.
  During Testing status, Google can expire refresh tokens after seven days.

For implementation boundaries and safety behavior, see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
