# Markdown Drive architecture

Last reviewed: 2026-08-21

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
- Drive change cursor coordination and Vault-boundary reconciliation;
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

A remote refresh requires a prior authoritative Vault load. While the application is active, one
application-scoped task refreshes immediately on foreground entry and then every 60 seconds; it is
stopped when the application resigns active. Stopping invalidates future ticks without cancelling a
safe Drive read that has already started, so ordinary backgrounding is not reported as a network
failure. A quick foreground return coalesces with that read instead of starting a full Vault reload.
The refresh reads the account-scoped Drive changes feed from the cursor persisted for that
account/Vault pair. Changes to IDs already in the tree,
folders or Markdown files newly found inside the live Vault boundary, and shared-drive-level changes
trigger a full authoritative tree reload. Changes proven to be outside the Vault and unrelated
non-Markdown files do not. The next cursor is persisted only after all relevant changes have been
reconciled and any required reload succeeds. A rejected cursor is removed and rebuilt around a new
full load. Remote refresh updates the tree but never replaces an open dirty editor buffer.

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
item moved outside the Vault stops the operation. For an open note, the preflight also compares the
current Drive revision with the editor's revision, and saving and renaming that note are serialized.
The returned item, revision, content checksum, and live ancestry are verified again after the write.
A checksum change means another client changed the note content during the rename window, so the
editor does not adopt the returned revision. An uncertain response or post-write verification
failure is reported as an unknown write status and is not retried automatically. The editor records
the verified revision without replacing its text or saved-text baseline, so unsaved edits remain
dirty and a later save does not mistake the app's own rename for an external conflict.

Moving an item to Google Drive Trash first re-fetches its metadata and live ancestry, requires the
item to remain inside the Vault, and requires Drive's explicit `capabilities.canTrash` permission.
The Vault root is never a valid target. The returned item must match the requested ID, name, and
kind and be marked as trashed; ambiguous write outcomes are not retried automatically. Items without
Trash capability are left unchanged for the Vault-local `_SMASH_TRASH` fallback path. After an
ambiguous outcome, mutations affecting the item remain locked until a metadata read confirms whether
the item is trashed. A confirmed Trash closes affected documents and cancels their pending loads; a
confirmed non-Trash result unlocks the item after refreshing the Vault tree.

When `capabilities.canTrash` is unavailable but `canMoveItemWithinDrive` is explicitly granted, the
same user action uses the Vault-local fallback. The app locates or creates `_SMASH_TRASH` directly
under the Vault root, identifies it by a private `appProperties` marker plus its locally persisted
Drive ID, and excludes that marked subtree from normal enumeration regardless of its current name.
Before moving an item, the app writes and re-reads its previous parent ID, deletion timestamp, and
soft-deleted marker. It then changes the parent with `addParents` and `removeParents` and verifies the
result with another metadata read. An ambiguous metadata or move write is not retried; reconciliation
recognizes either Drive Trash or a marked app Trash parent. Moving an item out of the control folder
therefore makes it visible again on the next refresh without changing its content.

An OAuth token permits broader Drive access than the Vault. Possession of that token or an arbitrary
file ID is never treated as proof of Vault membership.

## Local state and source of truth

Google Drive file content is the only authoritative document content. Local persistence is limited
to the Vault ID, OAuth refresh credential, and non-secret Drive change cursors scoped by account and
Vault. The in-memory editor buffer can temporarily differ from Drive while it is dirty or while an
error is being resolved, but it is not a second canonical store.

Refresh, failed authentication, failed networking, selection changes, and ordinary quit requests do
not silently discard a dirty buffer. Quitting with unsaved changes requires an explicit save,
cancellation, or destructive confirmation.

## Conflict detection and safe save

The revision snapshot contains Drive `version`, `modifiedTime`, and the strongest available content
checksum (`sha256Checksum`, then SHA-1 or MD5 as a compatibility fallback). Drive documents `version`
as a monotonically increasing value that reflects every server-side file change. The complete
snapshot must match the one captured when the file was opened.

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

- [Retrieve changes](https://developers.google.com/workspace/drive/api/guides/manage-changes)
- [Changes: list](https://developers.google.com/workspace/drive/api/reference/rest/v3/changes/list)
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
