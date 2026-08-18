# macOS MVP acceptance checklist

Use this checklist with a dedicated test Vault and a Google account configured as an OAuth test
user. Keep at least one nested folder, one owned Markdown file, and—when available—one Markdown file
owned by another account but editable by the test user.

Record failures with the affected item, whether it is owned or shared, and the exact app-visible
message. Never include OAuth credentials or document contents in an issue or log.

This is the release gate for the complete expanded MVP, not a claim that every item is implemented
or validated by the PR that introduced it. The first sections retain the Milestone 0–6 safe-editor
baseline; later sections cover planned Milestones 7–15. Keep every row unchecked until it has been
manually verified against the implementation that claims the corresponding milestone.

## Setup and restoration

- [ ] A sign-in attempt without local OAuth configuration shows a useful configuration error.
- [ ] A configured test user can complete browser sign-in and return to the app.
- [ ] An account not listed as a test user is rejected by Google without changing local files.
- [ ] A Vault can be selected from My Drive or a nested folder.
- [ ] **File > Change Vault…** can replace the selected Vault when no unsafe operation is pending.
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

## Remote changes, cache, and offline state — Milestone 7

- [ ] Remote create, edit, rename, move, and delete operations appear automatically while the app
  is active.
- [ ] Automatic refresh never replaces or discards a dirty editor buffer.
- [ ] Relaunch resumes from a persisted Drive change cursor without missing relevant Vault changes.
- [ ] An invalid or unreconcilable change cursor triggers a safe authoritative Vault reload.
- [ ] Changes outside the selected Vault are never surfaced through the change feed.
- [ ] Recently opened content and Quick Open/link/tag indexes can be rebuilt from Drive after the
  local cache is removed.
- [ ] Disconnecting the network or losing authentication disables every editor and mutating action.
- [ ] Reconnecting does not apply or upload any edit that was made while Drive was unavailable.

## Tabs and split editing — Milestone 8

- [ ] Multiple Markdown documents can remain open in tabs with independent selection and scroll
  state.
- [ ] Two documents can be displayed and edited in separate panes.
- [ ] Dirty, save, conflict, and remote-version state remain independent for every open document.
- [ ] A failed load, refresh, or save in one document does not alter another document's buffer.
- [ ] Closing a dirty tab requires an explicit safe decision for that document.
- [ ] Change Vault, Sign Out, and Quit account for every dirty tab and split pane.

## Autosave — Milestone 9

- [ ] Autosave waits for the configured debounce interval instead of writing every keystroke.
- [ ] Several edits to the same file are coalesced and writes for that file do not overlap.
- [ ] Autosave updates the same Drive file and retains the manual `⌘S` command.
- [ ] A newer remote version stops Autosave and opens the normal conflict flow.
- [ ] Autosave pauses while offline, unauthenticated, conflicted, or in an uncertain write state.
- [ ] An ambiguous Autosave response is never retried automatically.

## Syntax highlighting and preview — Milestone 10

- [ ] Headings, emphasis, links, code, lists, blockquotes, and YAML front matter are highlighted
  without modifying source text.
- [ ] Japanese IME composition, selection, undo/redo, scrolling, and find remain correct while
  highlighting is active.
- [ ] Source, Preview, and Source/Preview modes preserve the same document and dirty state.
- [ ] Rendering Markdown never changes the source or creates a Drive write.
- [ ] Unsafe embedded HTML or active content cannot execute through preview.
- [ ] Missing or inaccessible preview resources show a useful error without altering the buffer.

## Quick Open, Wiki Links, and Backlinks — Milestone 11

- [ ] `⌘P` finds Markdown files by fuzzy filename and Vault-relative path without searching bodies.
- [ ] Duplicate filenames are disambiguated by path and recent files appear predictably.
- [ ] A resolvable `[[note]]` opens the intended document in the multi-document workspace.
- [ ] Unresolved and ambiguous Wiki Links are shown clearly and are not guessed.
- [ ] Backlinks list every indexed note that links to the current document.
- [ ] Remote rename, move, and delete operations invalidate affected link and Backlink results.
- [ ] The app does not silently rewrite Wiki Links across the Vault.

## YAML front matter and tags — Milestone 12

- [ ] Valid front matter can be read and updated without dropping unrelated keys.
- [ ] Malformed front matter remains editable as source and is not silently normalized or replaced.
- [ ] YAML front matter remains the canonical source for tags.
- [ ] Tag case, normalization, and duplicate behavior match the documented rules.
- [ ] Tag browsing and filtering return the same results after rebuilding the local index from Drive.
- [ ] Missing or stale Drive metadata never removes tags from Markdown.

## Vault templates — Milestone 13

- [ ] A folder inside the current Vault can be selected as the template folder.
- [ ] Templates remain ordinary Markdown files visible to other Drive clients.
- [ ] Creating a note from a template never modifies the template itself.
- [ ] Title, date, and time variables expand according to the documented deterministic rules.
- [ ] Unknown or malformed variables remain intact or produce the documented useful error.
- [ ] Template-based creation follows ordinary naming, destination, boundary, and uncertain-write
  safety.

## Images and attachments — Milestone 14

- [ ] Existing private Vault-relative images render without public sharing.
- [ ] Paths containing traversal outside the Vault are rejected.
- [ ] Paste, drag and drop, and file-picker upload create attachments inside the selected Vault.
- [ ] Filename collisions produce a safe unique name without replacing an existing attachment.
- [ ] Markdown receives a portable relative link only after upload succeeds.
- [ ] Upload, cache, or insertion failure preserves the complete unsaved Markdown buffer.
- [ ] Moved, deleted, or inaccessible attachments fail visibly and recoverably.

## Expanded MVP hardening — Milestone 15

- [ ] Remote refresh, several tabs, split panes, and Autosave coexist without silent overwrite or
  buffer loss.
- [ ] Quick Open, links, tags, templates, preview, and attachments recover after a full cache/index
  rebuild.
- [ ] A Vault with at least 1,000 Markdown files and several nested levels remains usable.
- [ ] A Markdown document of at least 1 MB remains editable, highlightable, and previewable.
- [ ] Japanese IME and VoiceOver checks pass across tabs, splits, preview, dialogs, and new commands.
- [ ] Relaunch restores the expanded workspace without treating cached data as authoritative.
- [ ] Offline/read-only behavior queues no writes and returns safely to live Drive state after
  reconnection.
