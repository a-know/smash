# macOS MVP acceptance checklist

Use this checklist with a dedicated test Vault and a Google account configured as an OAuth test
user. Keep at least one nested folder, one owned Markdown file, and—when available—one Markdown file
owned by another account but editable by the test user.

Record failures with the affected item, whether it is owned or shared, and the exact app-visible
message. Never include OAuth credentials or document contents in an issue or log.

This is the release gate for the complete MVP, not a claim that every item is implemented or
validated by the PR that introduced this document. Keep every row unchecked until it has been
manually verified. Planned Milestone 6 polish remains listed here because it must pass before the
MVP can be called complete.

## Setup and restoration

- [ ] A sign-in attempt without local OAuth configuration shows a useful configuration error.
- [ ] A configured test user can complete browser sign-in and return to the app.
- [ ] An account not listed as a test user is rejected by Google without changing local files.
- [ ] A Vault can be selected from My Drive or a nested folder.
- [ ] Relaunch restores the signed-in session and the same Vault without repeated Keychain prompts.
- [ ] Sign out returns to the authentication screen, and signing in again restores the saved Vault.

## Browsing and refresh

- [ ] All existing `.md` files below the Vault appear automatically, including nested files.
- [ ] Unsupported and trashed files do not appear.
- [ ] Folder expansion state survives ordinary refresh and item creation.
- [ ] A file created by another Drive client appears after toolbar Refresh and `⌘R`.
- [ ] A remotely renamed, moved, or deleted item is reflected after refresh.
- [ ] `_SMASH_TRASH` and its descendants never appear in the normal Vault tree.

## Editing and saving

- [ ] Selecting a Markdown file downloads and displays its exact UTF-8 contents.
- [ ] Japanese IME composition, conversion, confirmation, undo, and redo work normally.
- [ ] `⌘F` opens native find and can locate text in the editor.
- [ ] Line wrapping and standard copy/paste/select-all commands work.
- [ ] Editing marks the document as changed, and `⌘S` updates the same Drive file.
- [ ] A failed or offline save retains the complete local editor text.
- [ ] Quitting with unsaved changes offers Save and Quit, Cancel, and Quit Without Saving.

## Conflicts and remote changes

- [ ] Editing the same file from another client before `⌘S` opens the conflict dialog.
- [ ] Cancel retains the local text without writing to Drive.
- [ ] Reload Remote Version replaces local text only after explicit confirmation.
- [ ] Save a Copy creates a distinct Markdown file and preserves the original remote file.
- [ ] Overwrite Anyway requires a second destructive confirmation and updates the original file.
- [ ] A file moved outside the Vault cannot be opened, saved, renamed, or trashed through a stale ID.

## File and folder operations

- [ ] `⌘N` creates a `.md` note in the chosen Vault folder and opens it.
- [ ] `⇧⌘N` creates a folder in the chosen Vault folder.
- [ ] Renaming a note preserves its `.md` extension by default.
- [ ] Empty or invalid names are rejected with a useful message.
- [ ] Renaming an open dirty note preserves its unsaved editor text.
- [ ] Owned files and folders move to Google Drive Trash after confirmation.
- [ ] Items without Trash capability but with Drive move capability use `_SMASH_TRASH` through the
  same confirmation flow.
- [ ] Items with neither Trash nor Drive move capability remain unchanged and show a useful error.
- [ ] A manually restored `_SMASH_TRASH` item reappears after refresh.
- [ ] Destructive folder actions always require confirmation.

## Authentication and failure recovery

- [ ] Revoking Google authorization leads to a clear reauthentication state without losing dirty
  text.
- [ ] Expired access tokens refresh without displaying or logging token values.
- [ ] Disconnecting the network during browsing shows a recoverable error.
- [ ] Disconnecting the network during editing does not alter the editor buffer.
- [ ] An uncertain save, create, rename, or Trash response is not retried automatically.
- [ ] While a Trash result is uncertain, affected editing and Vault switching remain locked until
  reconciliation completes.

## Accessibility and commands

- [ ] VoiceOver announces toolbar actions, the Vault tree, editor, loading states, and errors with
  meaningful labels.
- [ ] Keyboard focus can reach the sidebar, editor, toolbar, dialogs, and folder browser.
- [ ] `⌘N`, `⇧⌘N`, `⌘S`, `⌘F`, `⌘R`, and `⌘⌫` perform the documented actions.
- [ ] Disabled actions are unavailable when their operation would be unsafe.
