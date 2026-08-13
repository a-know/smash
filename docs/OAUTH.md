# Google OAuth design

Last reviewed: 2026-08-12

## Client type and flow

Markdown Drive uses a Google OAuth client whose application type is **Desktop app**.

The macOS app:

1. creates a cryptographically random PKCE verifier, S256 challenge, and `state` value;
2. binds a temporary HTTP listener to `127.0.0.1` on a random available port;
3. opens Google's authorization endpoint in the user's default browser;
4. validates the returned path and `state` before accepting the authorization code;
5. exchanges the code at `https://oauth2.googleapis.com/token` using the PKCE verifier; and
6. closes the loopback listener after the first callback.

The app never embeds Google's authorization page in a web view. The loopback IP redirect is Google's recommended callback mechanism for macOS desktop clients. `ASWebAuthenticationSession` is not used for this callback because its callback matchers do not model Google's random-port plain-HTTP loopback redirect. `NSWorkspace` opens the system's default browser instead.

Google documents the OAuth client secret as optional for installed applications. In live testing,
however, Google's token endpoint rejected a newly created Desktop client request without its issued
secret. Markdown Drive therefore sends the issued client secret during authorization-code exchange
and token refresh. A distributed native application cannot keep a shared client secret confidential,
so it identifies the OAuth client but is not treated as an authorization boundary. PKCE remains the
protection for the intercepted authorization-code threat.

Primary references:

- [OAuth 2.0 for iOS & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app)
- [OAuth 2.0 Policies](https://developers.google.com/identity/protocols/oauth2/policies)
- [OAuth 2.0 best practices](https://developers.google.com/identity/protocols/oauth2/resources/best-practices)

## Requested scope

The MVP requests exactly:

```text
https://www.googleapis.com/auth/drive
```

This is a restricted scope. It is required because the product must discover, download, edit, rename, and trash pre-existing files below a Vault chosen by the user, including files later created by another Drive client.

The narrower `drive.file` scope only grants per-item access to files created by the app or explicitly opened/shared with the app. Google Picker can return a selected folder ID, but Google does not document that selecting the folder recursively grants `drive.file` access to every existing or future descendant. Requiring the user to authorize every Markdown file would violate the product requirement.

The app verifies that the token response includes the requested Drive scope. It does not request identity, profile, email, or unrelated API scopes.

References:

- [Choose Google Drive API scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)
- [Google Picker for desktop and mobile apps](https://developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker)

## Vault boundary

The OAuth grant itself cannot be restricted to a Drive folder ID. Milestone 2 must therefore enforce a second, application-level boundary:

- normal listing and search start at the selected Vault root;
- every read, update, rename, move, and trash request verifies that its target is a Vault descendant;
- new items are created only below the Vault root;
- unrelated Drive items are never surfaced; and
- boundary enforcement is covered by automated tests.

An access token must never be treated as proof that an arbitrary file ID is inside the Vault.

## Dedicated-account isolation

Users who want a Google-enforced second boundary can use a dedicated Google account for the Vault:

1. create a Google account used only for Markdown Drive;
2. make that account the owner of the Vault where practical;
3. keep unrelated files and shares out of that account;
4. share the Vault with the user's regular account if other tools need access; and
5. authorize Markdown Drive as the dedicated account.

The `drive` token can only act on files accessible to the authenticated account, so this configuration isolates the user's primary Drive from the app. It does not convert `drive` into a folder-scoped OAuth grant: the consent text, restricted-scope classification, and Google verification requirements remain unchanged. The app still enforces its own Vault boundary.

Ownership matters for destructive operations. A collaborator may be able to edit or rename a file but not move it to Drive Trash. The app must inspect Drive's per-item `capabilities` fields instead of inferring operations solely from the account role. See the [deletion fallback](../SPEC.md#510-delete).

## Token lifecycle and storage

- The authorization request uses `access_type=offline` and `prompt=consent` so an installed app receives a refresh token.
- The refresh token is stored as a generic password in macOS Keychain with
  `AfterFirstUnlockThisDeviceOnly` accessibility.
- Access tokens are retained in memory and refreshed shortly before expiration.
- `invalid_grant` during refresh clears the stored credential and requires interactive sign-in.
- Sign-out first removes the local Keychain item and then makes a best-effort request to Google's revocation endpoint.
- Tokens and document contents must never be logged.

A user can also revoke the grant from the Google Account page under third-party app access:

<https://myaccount.google.com/connections>

Google notes that revocation affects the grant for the Cloud project, not only one local app installation.

## Local development setup

1. Create or select a Google Cloud project.
2. Enable Google Drive API.
3. Configure the Google Auth Platform consent screen and declare the Drive scope above.
4. While the app is in testing mode, add the Google accounts that will test it.
5. Create an OAuth client with application type **Desktop app**.
6. Open the Desktop client and obtain its client ID and client secret.
7. Create the ignored local configuration from the tracked example:

   ```sh
   cp Config/OAuth.local.xcconfig.example Config/OAuth.local.xcconfig
   ```

8. Paste the Desktop client values into `Config/OAuth.local.xcconfig`:

   ```text
   GOOGLE_OAUTH_CLIENT_ID = your client ID
   GOOGLE_OAUTH_CLIENT_SECRET = your client secret
   ```

`Config/OAuth.local.xcconfig` is ignored by Git. The tracked `Config/OAuth.xcconfig` imports it for
Debug and Release builds, and Xcode expands the values into the `GoogleOAuthClientID` and
`GoogleOAuthClientSecret` entries declared by `Config/MarkdownDriveMac-Info.plist`. A release
distribution necessarily contains the Desktop client credentials; do not rely on the client secret
to prevent impersonation of a native app.

Do not commit the local xcconfig, refresh tokens, access tokens, exported Keychain data, or downloaded
OAuth client JSON. Never print either OAuth credential in build or application logs.

The macOS target uses the repository owner's Apple Development team for a stable development code
signature. This is important for Keychain access: the access control attached when a refresh token is
created can recognize later builds with the same signed application identity. A contributor using a
different team should select their own Team under **Signing & Capabilities**.

Development builds created before stable code signing used the legacy service
`com.a-know.MarkdownDrive.oauth`. The application deliberately does not read that item because its
ad-hoc-signature access control could repeatedly prompt for the login Keychain password. The first
updated launch requires one Google sign-in and writes the replacement under
`com.a-know.MarkdownDrive.oauth.v2`. The old item can be removed manually from Keychain Access after
the new sign-in succeeds.

For an External consent screen whose publishing status is **Testing**, Google limits refresh tokens involving the Drive scope to seven days. Reauthentication after that interval is expected during development; it does not indicate a Keychain or refresh implementation failure. See [Google's refresh token expiration rules](https://developers.google.com/identity/protocols/oauth2#expiration).

## Publication and verification

The full Drive scope is restricted. A publicly distributed application must satisfy Google's OAuth verification requirements. If restricted-scope data is transmitted to or stored on a server, Google may additionally require a security assessment.

The MVP has no backend server: Drive data travels directly between the native app and Google. This reduces data handling but does not remove the restricted-scope verification requirement.
