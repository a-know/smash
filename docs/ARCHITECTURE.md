# Markdown Drive architecture

Last reviewed: 2026-08-13

## Product boundary

Markdown Drive is a native macOS Markdown source editor backed directly by a selected Google Drive
folder (the Vault). Google Drive is authoritative: the application does not maintain a separate note
database and does not require Google Drive for desktop.

The first application target is macOS 15 or later. Platform-neutral product and Drive logic lives in
`MarkdownDriveCore` so future iPadOS and iOS targets can reuse it without inheriting AppKit or macOS
window behavior.

## Major modules

### `MarkdownDriveCore`

The local Swift package contains:

- authentication state and access-token provider abstractions;
- Google Drive API request/response mapping;
- Drive item, Vault, tree, revision, and Markdown document models;
- recursive Vault tree loading and Markdown filtering;
- Vault-boundary checks for browsing, opening, saving, and item creation;
- UTF-8 document loading and dirty-state tracking; and
- conflict-aware save, conflict-copy, and explicit-overwrite operations.

Networking and storage dependencies are protocol-backed so tests use deterministic fakes and do not
require Google credentials.

### `MarkdownDriveMac`

The macOS application contains:

- SwiftUI navigation, toolbar, alerts, and menu commands;
- the AppKit-backed source editor and native find integration;
- browser-based OAuth presentation and the loopback callback server;
- Keychain refresh-token storage;
- UserDefaults Vault selection storage; and
- `AppModel`, which coordinates authentication, Drive loading, editor selection, and save UI state.

AppKit types do not cross into `MarkdownDriveCore`.

## Drive data flow

1. OAuth produces a short-lived access token; the refresh credential remains in Keychain.
2. The selected Vault ID is restored from UserDefaults.
3. `VaultTreeLoader` starts at that ID and recursively lists descendants, following every Drive API
   page. Only folders and Markdown files are exposed to the application UI.
4. Selecting or reloading a file verifies that its ID belongs to the loaded Vault tree and validates
   its current Drive ancestor chain before downloading. The chain is checked again after the stable
   UTF-8 download before the editor accepts the result.
5. The editor holds a `MarkdownDocument` containing the current text, last-saved text, and the Drive
   revision observed during the stable download.
6. Saving verifies the Vault boundary and remote revision again before updating the same Drive file
   ID.

Safe Drive reads retry once when Google rejects a cached access token: authentication refresh is
single-flight, the request is rebuilt with the refreshed token, and a second rejection requires the
user to authenticate again. Writes are never retried after an HTTP response because their commit
status may be ambiguous.

Creating a note or folder validates the selected destination against the current Vault tree and its
live Drive ancestor chain before sending `files.create`. Drive does not provide a documented atomic
precondition that ties creation to the parent's current ancestry, so the app validates the returned
item's ancestor chain again after creation. If the destination crossed the Vault boundary during the
request, the app attempts to move only the newly created item to Drive Trash. A failed or ambiguous
verification or cleanup is reported as an unknown write status and cannot be retried directly,
avoiding silent duplicates. This compensation narrows the race but cannot prevent another Drive
client from moving an ancestor after verification; later refresh, open, and mutation paths continue
to enforce the live Vault boundary.

Renaming a note or folder re-fetches the item and its ancestor chain before applying a metadata-only
`files.update`. A changed name, kind, Trash state, lost `capabilities.canRename` permission, or an
item moved outside the Vault stops the operation. The returned item and live ancestry are verified
again after the write. An uncertain response or post-write verification failure is reported as an
unknown write status and is not retried automatically. For an open note, the editor records the
revision returned by the rename without replacing its text or saved-text baseline, so unsaved edits
remain dirty and a later save does not mistake the app's own rename for an external conflict.

An OAuth token permits broader Drive access than the Vault. Possession of that token or an arbitrary
file ID is never treated as proof of Vault membership.

## Local state and source of truth

Google Drive file content is the only authoritative document content. Local persistence is limited
to the Vault ID and OAuth refresh credential. The in-memory editor buffer can temporarily differ from
Drive while it is dirty or while an error is being resolved, but it is not a second canonical store.

Refresh, failed authentication, failed networking, selection changes, and ordinary quit requests do
not silently discard a dirty buffer. Quitting with unsaved changes requires an explicit save,
cancellation, or destructive confirmation.

## Conflict detection and safe save

The revision snapshot is the pair of Drive `version` and `modifiedTime`. Drive documents `version` as
a monotonically increasing value that reflects every server-side file change. Both values must match
the snapshot captured when the file was opened.

The normal save path is:

1. verify that the file is present in the loaded Vault tree;
2. fetch current metadata and modification capabilities;
3. fetch the current parent chain and verify that it still reaches the Vault root;
4. compare the current revision with the opened revision;
5. stop and show the conflict UI when they differ;
6. otherwise, upload UTF-8 Markdown with `files.update` to the same file ID; and
7. record the returned revision as the new saved baseline.

The conflict UI keeps the local buffer and offers four deliberate outcomes:

- reload the remote version;
- create a uniquely named Markdown copy beside the original;
- overwrite the original after a second destructive confirmation; or
- cancel and continue editing.

Google Drive API v3 does not document a `files.update` version precondition or compare-and-swap
parameter. Consequently, the metadata comparison and media update are separate requests. The
preflight comparison prevents ordinary stale-editor overwrites but cannot make the network operation
atomic against a change occurring in the narrow interval between those requests. This limitation
must be reconsidered if Google introduces a documented conditional-update mechanism.

A write that loses its connection, receives a Drive 5xx response, or receives a success response that
cannot be validated has an ambiguous outcome: Drive might have committed it. The application does not
retry such writes automatically. It retains the local text and reports that the save status is
unknown. A later normal save rechecks Drive metadata first, turning a previously accepted update into
a conflict instead of blindly repeating the write. Conflict-copy creation uses the same rule to avoid
silently creating duplicate copies.

Primary Drive references:

- [Files: create](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/create)
- [Files: update](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/update)
- [File capabilities](https://developers.google.com/workspace/drive/api/guides/manage-sharing#capabilities)
- [Trash or delete files and folders](https://developers.google.com/workspace/drive/api/guides/delete)
- [File resource (`version`)](https://developers.google.com/workspace/drive/api/reference/rest/v3/files)
- [Manage file revisions](https://developers.google.com/workspace/drive/api/guides/manage-revisions)

## Error handling

Drive HTTP and transport failures are mapped into domain errors before reaching SwiftUI. User-visible
messages distinguish authentication, permission, remote deletion, Vault movement, conflict,
temporary service/rate-limit failures, malformed UTF-8, and ambiguous update outcomes. No error path
marks a dirty document clean unless Drive returned successful updated metadata for that content.

Normal tests use fake token, transport, Drive, and persistence services. Live Google Drive testing is
manual and opt-in.
