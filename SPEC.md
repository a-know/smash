# Markdown Drive for macOS — MVP Specification

## 1. Product summary

A small macOS-native Markdown editor whose source of truth is a user-selected Google Drive folder.

The application must work **without Google Drive for desktop**. It connects directly to Google Drive through OAuth 2.0 and the Google Drive API.

Primary usage model:

- iPhone / iPad: edit the same files with a separate Markdown editor such as Note.
- macOS: use this application.
- Storage: ordinary `.md` files in Google Drive.
- No proprietary note database.
- No backend server.
- No mandatory cloud service other than Google Drive.

The app should feel like a lightweight "Google Drive Markdown vault" rather than a general-purpose note-taking platform.

---

## 2. Product principles

1. **Google Drive is the source of truth**
   - Never require import into an app-owned database.
   - A note must remain an ordinary Markdown file.

2. **No Google Drive for desktop dependency**
   - All Drive access goes through Google Drive API.

3. **Folder-oriented**
   - The user selects one Google Drive folder as the root workspace ("Vault").
   - Existing Markdown files under that folder must be discoverable automatically.
   - The user must never register files one by one.

4. **Native macOS experience**
   - Swift + SwiftUI.
   - Keyboard-first operation.
   - Standard macOS menu commands and shortcuts where practical.

5. **Safe editing**
   - Avoid silently overwriting changes made on another device.
   - Fail visibly and recoverably when network or authentication errors occur.

6. **Staged, dependable MVP**
   - Build the expanded MVP in dependency-ordered milestones.
   - Do not trade data safety, Drive correctness, or Japanese editing reliability for breadth.

7. **Portable Markdown and attachments**
   - Markdown files should use ordinary relative paths for embedded images and attachments.
   - Do not write Google Drive file IDs or Drive-specific public URLs into Markdown unless explicitly required for interoperability.
   - The intended convention is a Vault-local attachments directory such as `attachments/`.
   - The app may resolve those relative paths to Google Drive file IDs internally.


8. **Portable tags**
   - Tag metadata should remain portable with the Markdown file.
   - The preferred source of truth is YAML front matter, e.g. `tags: [camera, travel]`.
   - Inline `#tags` may be supported later as an additional input format.
   - Google Drive metadata may be used as a rebuildable index/cache, but not as the sole canonical representation of tags.


9. **Obsidian-compatible Vault interoperability**
   - Avoid proprietary file formats or metadata that unnecessarily lock the Vault to this application.
   - Preserve compatibility with ordinary Markdown and, where practical, common Obsidian Vault conventions.
   - Treat Obsidian compatibility as interoperability, not as a goal to reimplement Obsidian.
   - Existing `.obsidian/` directories and unknown Vault files must be preserved and should not be modified unless a future feature explicitly requires it.

---

## 3. Target platform and stack

### Product platform strategy

The first shipping MVP targets **macOS only**, but the codebase must be structured from the beginning so that the core product can later support **iOS and iPadOS** without rewriting Google Drive integration, Vault logic, document models, conflict detection, or Markdown-domain logic.

The intended rollout is:

1. Phase 1 — macOS MVP
2. Phase 2 — iPadOS application
3. Phase 3 — iPhone application

Do not delay the macOS MVP by implementing all three platforms at once.

### Required for MVP

- macOS native application
- Swift
- SwiftUI
- URLSession for HTTP networking unless a compelling reason exists otherwise
- Google OAuth 2.0
- Google Drive API v3
- Apple AuthenticationServices for browser-based OAuth flow where appropriate
- Keychain for sensitive OAuth credentials / refresh tokens
- Swift concurrency (`async` / `await`) for asynchronous operations

### Shared-core requirement

Create a reusable shared module, preferably a local Swift Package such as:

```text
MarkdownDriveCore
```

It should contain platform-neutral logic where practical, including:

- Google Drive API client abstractions;
- OAuth/session domain interfaces where practical;
- Vault models and services;
- Drive file/folder models;
- recursive tree construction;
- conflict detection;
- Markdown document models;
- filtering and naming rules;
- Vault-relative path resolution for future images/attachments;
- front-matter/tag parsing and normalization for future tagging features;
- domain-level errors.

Platform-specific UI and lifecycle behavior should stay outside this module.

Do not force every API into the shared module if Apple platform APIs genuinely require a platform-specific adapter. Prefer clean interfaces over artificial portability.

### Avoid in MVP

- Electron
- Tauri
- embedded web application as the primary UI
- backend server
- proprietary note database
- Core Data / SwiftData as source-of-truth storage
- Firebase
- synchronization through Google Drive for desktop

Local app state such as selected folder ID, UI preferences, expanded folders, and recent files may be persisted locally.

---

## 4. Google Drive access model

### Initial setup

On first launch:

1. Show a short explanation:
   - This app edits Markdown files directly in Google Drive.
   - Google Drive for desktop is not required.
2. Ask the user to sign in to Google.
3. Complete OAuth authorization.
4. Let the user choose a Google Drive folder to use as the Vault root.
5. Save the selected folder's Drive file ID locally.
6. Load that folder and all descendant folders/files.

### OAuth

Use an OAuth client configured for a desktop/native application.

The implementation must use the minimum scope that still permits the product requirement that **all existing files below the chosen folder are automatically enumerable and editable**.

If a narrow `drive.file`-style scope cannot reliably enumerate pre-existing descendants of a selected folder, do not compromise the core UX by requiring per-file authorization. Prefer the Drive scope necessary to implement folder-level browsing, and restrict actual application behavior in code to the chosen Vault root.

Document the selected OAuth scope and rationale in `docs/OAUTH.md`.

OAuth access/refresh credentials must not be stored in plain-text preferences.

### Folder boundary

Even if the OAuth grant technically permits broader Drive access, the application must enforce a logical root boundary:

- The visible tree starts at the chosen Vault root.
- Search only searches descendants of that root.
- New files/folders are created only under that root.
- File move operations must not move content outside that root.
- No unrelated Drive content should be surfaced.

---

## 5. MVP scope

The MVP is considered complete when all items in this section work reliably.

### 5.1 Authentication

- Sign in with Google.
- Maintain the authenticated session across app launches where possible.
- Securely store credentials in Keychain.
- Handle expired access tokens.
- Sign out.
- Re-authenticate gracefully if credentials become invalid.

### 5.2 Vault selection

- Choose an existing Google Drive folder as Vault root.
- Persist the folder ID.
- Reopen the same Vault on subsequent launches.
- Provide "Change Vault…" in Settings or File menu.

A sophisticated graphical Google Drive picker is not mandatory for the first implementation if a simpler Drive folder browser inside the app is easier to implement reliably.

### 5.3 Recursive file tree

Display the selected Drive folder in a left sidebar.

Requirements:

- recursively show subfolders;
- show Markdown files with `.md` extension;
- optionally show `.markdown` and `.txt` behind a setting, but `.md` is mandatory;
- folders can expand/collapse;
- sort folders first, then files alphabetically;
- refresh button / command reloads the tree;
- creating a file from another device should become visible after refresh;
- deleted remote files disappear after refresh.

Example:

```text
Notes
├── ideas.md
├── memo.md
└── work
    ├── meeting.md
    └── project-a.md
```

### 5.4 Markdown file loading

When a Markdown file is selected:

- download the current file contents from Google Drive;
- decode text as UTF-8;
- show it in the editor;
- preserve ordinary Markdown text exactly unless the user edits it;
- retain relevant remote metadata needed for conflict detection.

The editor must support Japanese IME correctly.

### 5.5 Editing

MVP editor behavior:

- plain Markdown source editing;
- standard selection/copy/paste/undo/redo;
- Japanese text input;
- monospaced or readable configurable editor font;
- line wrapping;
- scroll;
- unsaved-change indication.

The expanded MVP requires IME-safe Markdown syntax highlighting and a rendered Markdown preview.
They must be layered on top of a proven plain-source editor and must not change source text merely by
rendering it.

### 5.6 Saving

- `⌘S` saves the current document.
- File > Save should also work.
- Save updates the same Google Drive file.
- Do not create an app-specific copy.
- Show a clear state such as:
  - Saving…
  - Saved
  - Save failed
  - Remote changes detected

The expanded MVP requires conflict-safe Autosave after explicit save and multi-document state are
stable. Manual `⌘S` must remain available.

### 5.7 New note

- `⌘N` creates a new Markdown file.
- Default extension is `.md`.
- User can choose the destination folder inside the Vault.
- The resulting file is created directly in Google Drive.
- It appears immediately in the file tree.

### 5.8 New folder

- Create a folder under the currently selected Vault folder.
- New folder is created directly in Google Drive.
- It appears immediately in the tree.

### 5.9 Rename

Support renaming files and folders within the Vault.

Rules:

- `.md` extension should be preserved by default when renaming a Markdown file.
- invalid/empty names must be rejected with a useful message.

### 5.10 Delete

Prefer moving files/folders to Google Drive Trash when the authenticated user's item capabilities permit it.

When an item is editable but cannot be moved to Drive Trash because it is owned by another account, use a recoverable Vault-local fallback:

- move the item into an app-managed folder displayed as `_SMASH_TRASH` under the Vault root;
- identify the control folder by its persisted Drive file ID and an app property, never by its name alone;
- exclude the control folder and all descendants from the normal Vault tree;
- preserve the item's previous parent ID and soft-deletion time as app control metadata so restoration remains possible;
- write and verify the restoration metadata before moving the item; if that cannot be done, leave the item unchanged;
- if neither Drive Trash nor a move into the control folder is permitted, leave the item unchanged and show an error.

The fallback is application-level soft deletion, not Google Drive Trash. It must remain inside the Vault boundary. A user manually moving an item out of `_SMASH_TRASH` makes it active again on the next refresh.

Require confirmation before deleting a folder.

### 5.11 Refresh

Provide:

- toolbar refresh button;
- keyboard-accessible refresh command.

Refresh should:

- fetch the latest folder/file structure;
- update metadata;
- not silently destroy unsaved local edits.

### 5.12 Conflict detection

This is a **required MVP feature**.

Scenario:

1. Open `memo.md` on Mac.
2. Edit the same file on iPhone/iPad.
3. Save remotely.
4. Return to Mac and try to save.

The Mac app must not silently overwrite the remote version.

At minimum:

- retain remote version metadata when the file is opened;
- immediately before saving, obtain current metadata from Drive;
- compare a suitable revision/version identifier or modification metadata;
- if remote content changed, stop the normal save.

Show a conflict dialog:

```text
This file was changed on another device.

[Reload Remote Version]
[Save a Copy]
[Overwrite Anyway]
[Cancel]
```

"Show Diff" is desirable but belongs to post-MVP unless easy to implement cleanly.

### 5.13 Error handling

MVP must handle at least:

- offline / network unavailable;
- OAuth token expiration;
- OAuth authorization revoked;
- Drive API permission failure;
- file deleted remotely;
- folder deleted remotely;
- file moved remotely;
- malformed/non-UTF-8 content;
- save conflict;
- Drive rate-limit/server error.

Errors should be user-readable and should not discard an unsaved editor buffer.

### 5.14 Automatic remote refresh and Drive change tracking

- Detect remote additions, edits, renames, moves, and deletions while the app is active.
- Use Google Drive Changes API with a persisted change cursor after an initial authoritative Vault
  load.
- Treat the change feed as an invalidation/delta source, not as permission to bypass Vault-boundary
  checks.
- Reconcile only changes relevant to the selected Vault and recover with a full reload when the
  cursor is invalid, expired, or cannot prove a safe result.
- Never replace a dirty editor buffer automatically.
- Avoid wasteful polling and coalesce overlapping refresh work.

### 5.15 Local read and index cache

- Cache recently opened document contents for faster reads and maintain rebuildable indexes needed
  by Quick Open, Wiki Links, Backlinks, and tags.
- Cache entries must retain enough remote identity/version metadata to detect staleness.
- Google Drive remains authoritative; cached contents and indexes must be disposable and
  rebuildable.
- The cache does not authorize editing. If Drive connectivity or a valid authenticated session is
  unavailable, all editing and mutating actions must be disabled.
- Offline editing, queued writes, and later synchronization are explicitly outside MVP.

### 5.16 Multi-document workspace

- Open multiple Markdown documents in tabs.
- Support a split editor with two independently selected open documents.
- Track text, dirty state, remote version, save state, and conflict state per open document.
- Closing a dirty tab, changing Vaults, signing out, or quitting must offer a safe decision for
  every affected dirty document.
- A load, refresh, save, or conflict in one tab must not discard or overwrite another tab's buffer.

### 5.17 Conflict-safe Autosave

- Debounce ordinary edits before saving; do not send a Drive write for every keystroke.
- Perform the same remote-version and Vault-boundary checks as manual save.
- Serialize/coalesce saves per file and never retry an ambiguous write automatically.
- Pause Autosave when offline, unauthenticated, conflicted, or when remote status is uncertain.
- Preserve `⌘S` and a visible per-document save state.

### 5.18 Markdown syntax highlighting

- Highlight at least headings, emphasis, links, code spans/fences, lists, blockquotes, and YAML
  front matter.
- Preserve exact source text, selection, undo/redo, scrolling, and Japanese IME composition.
- Highlighting must remain usable for files of at least the MVP performance target size.

### 5.19 Markdown preview

- Provide source, preview, and source/preview split modes without rewriting the Markdown source.
- Render ordinary Markdown and supported Vault-relative images/attachments.
- Sanitize or disable unsafe embedded HTML and active content.
- Missing, inaccessible, or moved attachments must fail visibly without affecting the editor buffer.

### 5.20 Quick Open

- `⌘P` opens a keyboard-first file picker.
- Search Markdown filenames and Vault-relative paths with fuzzy matching.
- Include recent files and disambiguate duplicate filenames by path.
- Opening a result must obey normal multi-document and dirty-buffer safety rules.
- Full-text body search is not required.

### 5.21 Wiki Links and Backlinks

- Recognize conventional `[[note]]` Wiki Links, including a documented disambiguation rule for
  duplicate names and optional display aliases if supported.
- Activating a resolvable Wiki Link opens the target document; unresolved and ambiguous links are
  shown clearly and never guessed destructively.
- Show Backlinks for the current document using a local, rebuildable index derived from Markdown.
- Define and test how remote rename/move/delete operations invalidate link and Backlink results.
- Do not rewrite links across the Vault automatically unless a later explicit feature defines a
  safe transactional behavior.

### 5.22 YAML front matter and tags

- Parse and update YAML front matter in shared core without dropping unknown keys, comments, or
  formatting that the app does not own where practical.
- Treat YAML front matter as the canonical tag source; local indexes and Drive metadata are derived
  and rebuildable.
- Support tag browsing/filtering and consistent normalization with documented case and duplicate
  rules.
- Malformed front matter must remain editable as source and must not be silently rewritten.
- Inline `#tags` and Google Drive Labels are optional and are not canonical for MVP.

### 5.23 Vault templates

- Store templates as ordinary Markdown files inside the selected Vault so they synchronize and
  remain portable across clients.
- Let the user select which Vault folder contains templates and exclude templates from ordinary
  note creation only when that behavior is explicit and reversible.
- Create a new note from a template without modifying the template file.
- Support a small documented set of deterministic variables, such as date, time, and requested note
  title; unknown variables must remain intact or produce a clear error.
- Template creation must use the same naming, destination, conflict, and ambiguous-write safety as
  ordinary note creation.

### 5.24 Images and attachments

- Resolve ordinary Vault-relative paths through a shared `VaultPathResolver` without allowing path
  traversal outside the selected Vault.
- Display existing private images in preview through authenticated Drive API access.
- Upload images and attachments by paste, drag and drop, or an appropriate file picker.
- Use collision-safe filenames and insert a relative Markdown link only after upload succeeds.
- Preserve unsaved Markdown when upload or link insertion fails.
- Binary caches are disposable and never authoritative; attachments need not be publicly shared.

---

## 6. Explicit MVP non-goals

Do **not** implement these before the core workflow is stable:

- Obsidian plugin compatibility
- graph view
- full-text search across file bodies
- rich-text/WYSIWYG editing
- Mermaid
- KaTeX / MathJax
- PDF export
- HTML export
- Git integration
- multiple simultaneous Vaults
- collaborative editing
- realtime push synchronization
- offline-first filesystem mirror
- iCloud support
- Dropbox / OneDrive support
- iOS/iPadOS version
- App Store distribution
- Chrome extension
- custom cloud backend
- AI features

---

## 7. Suggested UI for MVP

Use a `NavigationSplitView` or equivalent macOS-native layout.

```text
┌──────────────────────────────────────────────────────────┐
│ Markdown Drive                          ↻        Settings │
├───────────────────┬──────────────────────────────────────┤
│ Vault             │ memo.md                              │
│                   │                                      │
│ ▼ Notes           │ # Memo                               │
│   ideas.md        │                                      │
│   memo.md         │ Markdown text...                     │
│ ▼ work            │                                      │
│   meeting.md      │                                      │
│   project-a.md    │                                      │
│                   │                                      │
│ + Note  + Folder  │                              Saved ✓ │
└───────────────────┴──────────────────────────────────────┘
```

### Toolbar

Recommended MVP actions:

- New note
- New folder
- Refresh
- Current save status
- Settings

### Menus / shortcuts

At minimum:

- New Note — `⌘N`
- Save — `⌘S`
- Refresh — `⌘R` if it does not conflict with platform behavior
- Find in current document — `⌘F`
- Preferences/Settings — standard macOS convention

---

## 8. Architecture guidance

The architecture should explicitly separate reusable product logic from platform UI.

Suggested structure:

```text
MarkdownDrive
├── MarkdownDriveCore
│   ├── Domain
│   │   ├── DriveItem
│   │   ├── MarkdownDocument
│   │   ├── Vault
│   │   └── Conflict
│   ├── Services
│   │   ├── DriveAPIClient
│   │   ├── VaultService
│   │   └── ConflictDetector
│   └── Support
│       ├── Filtering
│       └── DomainErrors
│
├── MarkdownDriveMac
│   ├── UI
│   │   ├── VaultSidebar
│   │   ├── EditorView
│   │   ├── AuthenticationView
│   │   └── SettingsView
│   ├── PlatformServices
│   │   ├── GoogleOAuthService
│   │   └── KeychainService
│   └── State
│       └── AppModel / ViewModels
│
└── Future
    ├── MarkdownDriveiPad
    └── MarkdownDriveiPhone
```

The exact project/target layout may differ if a cleaner SwiftPM/Xcode arrangement is justified, but the separation of reusable core from macOS-specific UI must remain.

Prefer protocol-driven services so Drive and authentication behavior can be tested with fakes.

Example conceptual protocols:

```swift
protocol DriveClient {
    func listChildren(of folderID: String) async throws -> [DriveItem]
    func downloadFile(id: String) async throws -> DriveFileContent
    func createMarkdownFile(name: String, parentID: String, contents: String) async throws -> DriveItem
    func createFolder(name: String, parentID: String) async throws -> DriveItem
    func updateFile(id: String, contents: String) async throws -> DriveItem
    func renameItem(id: String, name: String) async throws -> DriveItem
    func trashItem(id: String) async throws
    func getMetadata(id: String) async throws -> DriveItemMetadata
}
```

Do not treat this sample interface as immutable if Google Drive semantics suggest a better abstraction.

---

## 9. Local persistence

Allowed local persistence:

- selected Vault folder ID;
- selected Vault display name;
- UI preferences;
- last opened file ID;
- sidebar expansion state;
- recent files;
- non-secret cache metadata.

Sensitive OAuth material must use Keychain.

Do not persist note contents locally as the authoritative version.

A transient editor buffer/cache is allowed, especially to protect unsaved work after errors, but it must never become a competing source of truth.

---

## 10. Testing requirements

### Unit tests

At minimum:

- recursive Drive tree construction;
- Vault root boundary enforcement;
- Markdown extension filtering;
- rename logic;
- conflict detection;
- save state transitions;
- error mapping;
- authentication state transitions.

### Service tests

Use mock/fake Drive responses for normal operation and failures.

Do not require real Google credentials for the normal automated test suite.

### Manual acceptance tests

Perform these against a test Google Drive folder:

1. Sign in.
2. Select a folder containing nested `.md` files.
3. Verify all existing Markdown files appear without registering them individually.
4. Open and edit Japanese text.
5. Save with `⌘S`.
6. Verify the same Drive file changed in Google Drive Web.
7. Edit that file from another client and verify the Mac conflict warning.
8. Create a note on Mac and verify it appears in Drive.
9. Create a note from another client and verify it appears after refresh.
10. Rename a note.
11. Create a folder.
12. Trash a note.
13. Relaunch the app and verify the Vault is restored.
14. Revoke Google authorization and verify graceful recovery.
15. Disconnect networking while editing and verify the editor buffer is retained.
16. Verify remote create/rename/move/delete changes appear automatically without replacing a dirty
    buffer.
17. Open several tabs and both split panes, then verify each retains independent text and save state.
18. Verify Autosave updates the same Drive file and stops on conflicts or uncertain writes.
19. Verify syntax highlighting and preview do not break Japanese IME, undo, or source text.
20. Use Quick Open, Wiki Links, and Backlinks with nested files and duplicate filenames.
21. Edit tags through YAML front matter and rebuild the local tag index from Drive.
22. Create a note from a Vault-stored template and verify the template remains unchanged.
23. Display and upload a private image/attachment and verify the Markdown uses a relative path.
24. Relaunch and rebuild the read/index cache without changing Drive data.
25. Disconnect networking and verify all editing and mutation controls are disabled and no write is
    queued for reconnection.

---

## 11. Definition of MVP done

MVP is done when a user can:

> Launch the macOS app, authenticate to Google, select one Drive folder once, see and automatically
> refresh its Markdown tree, safely work with multiple source/preview documents, save manually or
> automatically without silent overwrites, navigate through Quick Open and Wiki Links/Backlinks,
> organize portable YAML tags and Vault templates, create/rename/trash notes and folders, use private
> Vault-relative images and attachments, relaunch into the same workspace, and safely coexist with
> edits made from another device.

The local cache and all indexes must be rebuildable from Drive. Loss of connectivity must make the
expanded MVP read-only: it must never queue offline edits or writes for later synchronization.

### Expanded MVP delivery sequence

The original safe text-editor baseline ends at Milestone 6. Complete the expanded MVP in this
dependency order:

1. **Milestone 7 — Remote changes and disposable cache:** Drive Changes API, automatic refresh,
   recent-document cache, rebuildable indexes, and strict read-only offline behavior.
2. **Milestone 8 — Multi-document workspace:** per-document sessions, tabs, split editing, and safe
   handling of multiple dirty buffers.
3. **Milestone 9 — Conflict-safe Autosave:** per-file debounce/coalescing with the same conflict and
   uncertain-write safety as manual save.
4. **Milestone 10 — Syntax highlighting and preview:** IME-safe highlighting plus source, preview,
   and source/preview modes.
5. **Milestone 11 — Quick Open and links:** `⌘P`, Wiki Link resolution, and rebuildable Backlinks.
6. **Milestone 12 — YAML front matter and tags:** loss-aware parsing, canonical portable tags, and
   tag browsing/filtering.
7. **Milestone 13 — Vault templates:** ordinary Vault Markdown templates, safe creation, and a small
   deterministic variable set.
8. **Milestone 14 — Images and attachments:** safe relative-path resolution, private rendering,
   upload, and Markdown insertion.
9. **Milestone 15 — Expanded MVP hardening:** combined acceptance, performance, cache rebuild,
   offline/read-only, accessibility, and Japanese IME regression checks.

---

# 12. Expanded-MVP feature notes and post-MVP roadmap

Several features originally recorded below as post-MVP have now been promoted into the expanded
macOS MVP. Sections 5.14–5.24 and the milestones in `AGENTS.md` are authoritative for their required
scope. The remaining unpromoted features in this section stay post-MVP.

## P1 — High-value next features

### 12.1 Automatic remote refresh

**Expanded MVP — Milestone 7.**

- Periodically refresh Drive metadata while the app is active.
- Detect remote additions/deletions/renames.
- Avoid intrusive polling.
- Never replace a dirty editor buffer automatically.

### 12.2 Full-text search

- Search across filenames and Markdown bodies inside the Vault.
- `⌘⇧F` global search.
- Show snippets and file paths.

Implementation should account for the fact that Drive API search does not provide arbitrary full-text Markdown-content semantics equivalent to a local index. A local, rebuildable search index may be appropriate, provided Drive remains source of truth.

### 12.3 Markdown syntax highlighting

**Expanded MVP — Milestone 10.**

- Headings
- emphasis
- links
- code spans/fences
- lists
- blockquotes
- front matter

Must remain IME-safe.

### 12.4 Markdown preview

**Expanded MVP — Milestone 10.**

- Rendered preview.
- Toggle source / preview.
- Prefer standards-compatible Markdown rendering.
- Sanitise HTML where appropriate.

### 12.5 Conflict diff

When a conflict occurs:

- fetch remote version;
- show local vs remote diff;
- allow user to choose local, remote, or manually merge.

### 12.6 Quick Open

**Expanded MVP — Milestone 11.**

`⌘P`:

- fuzzy filename/path search;
- keyboard-only file navigation;
- recent files.

### 12.7 Autosave

**Expanded MVP — Milestone 9.**

Requirements:

- debounce edits;
- retain conflict detection;
- explicit status indicator;
- never silently overwrite newer remote content.

---

## P2 — Knowledge-management features

### 12.8 Wiki links

**Expanded MVP — Milestone 11.**

Support:

```markdown
[[meeting-notes]]
```

Resolve links within the Vault.

### 12.9 Backlinks

**Expanded MVP — Milestone 11.**

Show notes that link to the currently open note.

### 12.10 Tags

**Expanded MVP — Milestone 12.**

Tags should preserve Markdown portability.

#### Canonical representation

Prefer YAML front matter as the source of truth:

```yaml
---
tags:
  - camera
  - travel
  - idea
---
```

Inline tags such as:

```markdown
#camera #travel
```

may also be recognized later, but should not be the only canonical representation unless product requirements change.

#### Indexing strategy

The application may build a local rebuildable tag index for fast filtering/search.

Google Drive `appProperties` may also be evaluated as an optional secondary index/cache, for example to accelerate Drive-side queries. If used:

- YAML front matter remains canonical;
- `appProperties` must be treated as rebuildable derived metadata;
- stale or missing Drive metadata must never cause tag loss;
- tag edits should update Markdown first, then derived metadata.

#### Google Drive Labels

Google Drive Labels may be supported as an optional integration for Google Workspace environments.

They are not the primary tag model because:

- availability and administration depend on Workspace configuration;
- they are less portable than Markdown-embedded metadata;
- ordinary personal Google Drive usage should not depend on them.

If added later, Drive Labels should be treated as an integration/export/synchronization layer rather than the sole source of truth.

#### UX ideas

Potential future functionality:

- tag browser/sidebar;
- filter by one or multiple tags;
- tag autocomplete;
- tag rename across the Vault;
- tag counts;
- recent tags;
- hierarchical tags such as `project/mobile`;
- tag chips in note metadata UI.

### 12.11 YAML front matter

**Expanded MVP — Milestone 12.**

Improve editing and optional structured display.

### 12.12 Daily notes

Configurable daily-note path and filename template.

Example:

```text
daily/2026-08-11.md
```

### 12.13 Multiple tabs

**Expanded MVP — Milestone 8.**

Allow several notes to remain open.

### 12.14 Split editor

**Expanded MVP — Milestone 8.**

Two notes side-by-side, or source + preview.

---

## P3 — Rich Markdown support

### 12.15 GitHub Flavored Markdown

- task lists
- tables
- strikethrough
- autolinks

### 12.16 Mermaid

Render fenced Mermaid blocks in preview.

### 12.17 Math

KaTeX or equivalent mathematical rendering in preview.

### 12.18 Images and attachments

**Expanded MVP — Milestone 14.**

Images and attachments are a planned feature and must preserve ordinary Markdown portability.

Preferred Vault convention:

```text
Vault/
├── memo.md
├── work/
│   └── project.md
└── attachments/
    ├── screenshot-20260811.png
    └── architecture.png
```

Markdown should reference files with normal relative paths, for example:

```markdown
![Architecture](attachments/architecture.png)
```

or, from a nested note, an equivalent correct relative path.

#### Internal resolution model

The application should treat Google Drive as a virtual filesystem:

```text
relative Vault path
    ↓
resolve folders/files within Vault
    ↓
Google Drive file ID
    ↓
download binary content through Drive API
```

A shared component such as `VaultPathResolver` should live in `MarkdownDriveCore` and be reusable by macOS, iPadOS, and iPhone.

#### Important portability rule

Do **not** store Google Drive file IDs in Markdown syntax as the default representation.

Do **not** require attachments to be publicly shared.

The app should retrieve private images through the authenticated Google Drive API.

This preserves the Markdown and folder structure so that, when the Vault is available as an ordinary filesystem (for example through Google Drive for desktop on another machine), conventional Markdown editors can resolve the same relative links.

#### Expanded MVP step 1 — Read/display existing images

After the source editor and Markdown preview are stable:

- parse image references using relative paths;
- resolve those paths inside the Vault;
- fetch images from Google Drive;
- display them in Markdown preview;
- cache image bytes transiently for performance;
- invalidate cache when remote metadata changes;
- handle missing/moved/deleted attachments gracefully.

#### Expanded MVP step 2 — Add images and attachments

Support:

- drag-and-drop image insertion on macOS/iPadOS where appropriate;
- paste image from clipboard;
- Photos/file picker on iOS/iPadOS;
- upload binary file into the Vault attachment directory;
- generate a collision-safe filename;
- insert the relative Markdown image syntax at the cursor.

Example:

```markdown
![](attachments/20260811-123456.png)
```

#### Future attachment types

The same resolver may later support:

- PDF;
- audio;
- arbitrary linked files.

Do not assume every attachment must be rendered inline.

---

## P4 — Better sync/offline behavior

### 12.19 Local read cache

**Expanded MVP — Milestone 7.**

Cache recently opened notes for faster startup and maintain rebuildable indexes for promoted MVP
features.

Drive remains source of truth.

When Drive connectivity or authentication is unavailable, cached content may be displayed only as
clearly stale read-only content. Editing and all mutation controls must be disabled.

### 12.20 Offline editing queue

Allow edits while offline and sync later.

This is substantially more complex because it introduces:

- queued writes;
- conflict resolution after reconnect;
- local version tracking;
- durable recovery.

This remains explicitly outside the expanded MVP. Do not permit offline edits or queue writes.

### 12.21 Google Drive Changes API

**Expanded MVP — Milestone 7.**

Use the Drive changes feed to discover remote modifications efficiently, with persisted cursor
handling, Vault-boundary reconciliation, and a safe full-reload fallback.

---

## P5 — Additional platforms / integrations

### 12.22 iPadOS app — Phase 2

This is the preferred first platform expansion after the macOS MVP.

Goals:

- reuse `MarkdownDriveCore`;
- use the same Google Drive Vault;
- reuse authentication/session logic where platform APIs permit;
- use `NavigationSplitView` for sidebar + editor layouts;
- support hardware keyboard shortcuts such as `⌘N`, `⌘S`, `⌘F`, and later `⌘P`;
- preserve the same conflict-detection semantics as macOS;
- keep Google Drive as the sole source of truth.

The iPad app should feel like the same product adapted to touch and keyboard input, not a separate note system.

### 12.23 iPhone app — Phase 3

After iPadOS is stable, add an iPhone-oriented navigation model.

Likely UX:

```text
Vault
  → Folder
    → Note
      → Editor
```

Goals:

- reuse `MarkdownDriveCore`;
- prioritize fast note opening and editing;
- use a compact navigation stack rather than forcing the macOS/iPad split-view layout onto a phone;
- preserve the same Drive storage, file operations, and conflict rules.

### 12.24 Other cloud providers

### 12.24 Other cloud providers

Potential providers:

- Dropbox
- OneDrive
- WebDAV

Abstract only when there is a concrete need; do not over-engineer MVP around hypothetical providers.

### 12.25 Git integration

Optional commit/push workflow for users who mirror Drive content into Git separately.

### 12.26 Export

- HTML
- PDF
- printable view

---

## P6 — AI features (optional, much later)

Only consider after the core editor is dependable.

Potential features:

- summarize selected note;
- rewrite selected paragraph;
- generate title;
- semantic search;
- cross-note Q&A.

AI features must be opt-in and must make clear when note contents leave the device/Google Drive for an AI provider.

---


### 12.27 Obsidian-compatible Vault interoperability

Maintain practical interoperability with Obsidian Vaults without making Obsidian a runtime dependency.

Compatibility targets may include:

- ordinary `.md` files;
- YAML front matter / Properties conventions where practical;
- tags stored in portable Markdown metadata;
- Vault-relative image and attachment links;
- `[[Wiki Links]]` when Wiki Link support is implemented;
- preservation of `.obsidian/` configuration directories;
- preservation of unknown files and directories in the Vault.

A Vault stored in Google Drive should ideally be usable in two ways:

```text
Google Drive / MyVault
        │
        ├── Markdown Drive app
        │     └── Drive API access
        │
        └── Obsidian
              └── local filesystem access when the same Drive folder
                  is available through Google Drive for desktop
```

Non-goals:

- full Obsidian plugin API compatibility;
- reproducing every Obsidian feature;
- interpreting or rewriting arbitrary `.obsidian/` configuration;
- requiring Obsidian for normal application operation.

When there is a choice between an app-specific representation and a widely understood Markdown/Obsidian convention that satisfies the same requirement safely, prefer the portable convention.


## 13. Security and privacy

- Do not send note contents or attachment contents to any server other than Google Drive in MVP.
- Do not add analytics that capture document names or contents.
- Do not log OAuth tokens.
- Do not log note contents in production logs.
- Store secrets/tokens in Keychain.
- Prefer least privilege consistent with the core requirement.
- Clearly explain requested Google OAuth permissions.
- Restrict app behavior to the selected Vault root even if OAuth scope is broader.
- Make destructive operations explicit and recoverable through Google Drive Trash when possible.

---

## 14. Performance targets

MVP should remain usable with at least:

- 1,000 Markdown files;
- nested folders several levels deep;
- individual Markdown files of at least 1 MB.

Do not prematurely optimize, but avoid obviously N+1/sequential network traversal when Drive API queries can batch or page results efficiently.

Use pagination correctly.

---

## 15. Open implementation decisions

Codex should investigate these before implementation and document the decision:

1. Exact Google Drive OAuth scope required for enumerating all pre-existing descendants of the selected folder.
2. Best native-app OAuth redirect mechanism for the current Google OAuth requirements on macOS.
3. Reliable remote-version identifier for conflict detection:
   - Drive `version`,
   - `modifiedTime`,
   - revision metadata,
   - or another authoritative mechanism.
4. Whether recursive tree loading should:
   - query per-folder,
   - query all descendants iteratively,
   - or maintain a cached tree.
5. Best native text editing component for:
   - large Markdown files,
   - Japanese IME,
   - future syntax highlighting.
6. Exact Swift package/target boundary for `MarkdownDriveCore` so that future iOS/iPadOS applications can reuse Drive, Vault, conflict, and document logic without inheriting macOS-only APIs.
7. Vault-relative attachment path semantics:
   - canonical attachments directory name;
   - path normalization;
   - handling `../` segments;
   - case sensitivity expectations;
   - duplicate filenames;
   - behavior when files are moved or renamed.
8. Tag semantics:
   - canonical YAML front matter shape;
   - normalization/case rules;
   - duplicate tag handling;
   - whether inline `#tags` merge with front-matter tags;
   - whether/how Google Drive `appProperties` are used as derived metadata;
   - optional Google Workspace Drive Labels integration.

Prefer correctness and maintainability over cleverness.

---

## 16. Reference documentation

Before implementing Google or Apple platform integrations, verify current behavior against primary documentation:

- Google OAuth 2.0 documentation
- Google Drive API v3 documentation
- Google Drive API authorization scopes
- Apple AuthenticationServices / ASWebAuthenticationSession
- Apple Keychain Services

Do not rely on stale blog posts for security-sensitive integration details.
