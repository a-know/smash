# AGENTS.md

## Project mission

Build a focused Markdown editor whose first MVP is a macOS-native application backed directly by a Google Drive folder.

The macOS MVP is Phase 1 of a planned Apple-platform product:

1. macOS MVP
2. iPadOS
3. iPhone

Do not implement all three platforms during the MVP, but structure reusable code so the future iOS/iPadOS applications do not require rewriting the product core.

Read `SPEC.md` completely before making architectural or implementation decisions.

The core workflow is:

> Google Drive folder → automatically enumerate existing Markdown files → open/edit → safely save back to the same Drive file.

Google Drive is the source of truth. The application must not require Google Drive for desktop.

---

## Priority order

When trade-offs arise, optimize in this order:

1. data safety;
2. correct Google Drive behavior;
3. reliable OAuth/session handling;
4. correct Japanese text editing;
5. simple native macOS UX;
6. maintainable architecture;
7. additional Markdown features.

Do not sacrifice items 1–5 to add post-MVP features.

---

## MVP boundary

Implement only the macOS MVP defined in `SPEC.md` unless explicitly asked otherwise.

Future iOS/iPadOS support is an **architectural constraint**, not an MVP deliverable.

In particular, do not spontaneously add:

- Obsidian compatibility;
- backlinks;
- graph view;
- tags;
- Markdown preview;
- WYSIWYG editing;
- Mermaid;
- math rendering;
- AI features;
- Git integration;
- multiple cloud providers;
- offline sync;
- realtime collaboration;
- telemetry frameworks.

A smaller reliable application is preferred.

---

## Required technology

- Swift
- SwiftUI
- macOS native app for MVP
- a reusable shared Swift module/package for platform-neutral product logic
- Swift concurrency
- Google Drive API v3
- OAuth 2.0
- AuthenticationServices where appropriate
- Keychain for sensitive credentials

Avoid Electron/Tauri unless the user explicitly changes the architecture.

---

## Architectural rules

### Shared Apple-platform core

Create a reusable core module, preferably `MarkdownDriveCore`.

Place platform-neutral logic there when practical:

- Google Drive API abstractions and request/response mapping;
- Vault domain logic;
- Drive tree construction;
- document models;
- filtering/naming rules;
- conflict detection;
- Vault-relative path resolution for future images/attachments;
- domain errors.

Keep macOS-specific views, menu commands, window behavior, and platform-only adapters outside the core.

Design the core so a later iPadOS/iPhone target can consume it directly.

Do not over-generalize for non-Apple platforms or hypothetical cloud providers.

### Drive is authoritative

Never introduce an app-owned note database as the source of truth.

Local persistence may store:

- Vault folder ID;
- UI preferences;
- expansion state;
- recent/open file IDs;
- non-secret cache metadata.

A transient or recovery cache for unsaved text is acceptable, but it must not become a parallel canonical document store.

### Enforce Vault boundaries

Even if OAuth permissions allow broader Google Drive access, application logic must limit normal operations to descendants of the selected Vault root.

### Service boundaries

Keep OAuth, Drive networking, Keychain access, and UI state separable.

Prefer protocol-backed services that can be replaced with fakes in tests.

### Networking

- Use async/await.
- Handle Drive API pagination.
- Map HTTP/API errors into domain-level errors.
- Avoid blocking the main actor with network work.
- Add retries only where semantically safe.
- Do not retry destructive or ambiguous writes blindly.

---


## Obsidian interoperability rules

Treat Obsidian as an interoperability target, not a dependency and not a feature-completeness target.

When designing Markdown-visible data:

- prefer ordinary Markdown;
- prefer portable YAML front matter for structured metadata;
- prefer Vault-relative attachment paths;
- preserve `.obsidian/` and unknown Vault content;
- do not introduce proprietary metadata when a common Markdown/Obsidian convention is sufficient;
- do not modify Obsidian configuration files unless explicitly implementing a documented interoperability feature.

Future Wiki Link support should consider conventional `[[note]]` syntax.

Do not spend MVP time implementing Obsidian-specific UI, plugins, graph view, backlinks, or configuration parsing. Compatibility must not expand the MVP scope.


## Tagging rules

Tagging is post-MVP, but preserve a portable design.

Canonical principle:

- tag source of truth lives in Markdown, preferably YAML front matter;
- local indexes are derived and rebuildable;
- Google Drive `appProperties` may be used later as derived search metadata;
- Google Drive Labels are optional Workspace-specific integration, not the canonical tag store.

Do not design a proprietary tag database that becomes necessary to interpret the user's files.

When tag support is implemented:

- parse and normalize tags in shared core;
- update Markdown content first;
- rebuild/update secondary indexes afterward;
- never lose tags because Drive metadata is stale or absent;
- keep behavior consistent across macOS, iPadOS, and iPhone.

## Attachment and image rules

Image/attachment support is post-MVP, but the architecture must not make it difficult later.

Canonical design:

- attachments live inside the selected Google Drive Vault;
- Markdown uses ordinary relative paths;
- app code resolves relative paths to Drive file IDs internally;
- Google Drive-specific file IDs or public URLs must not be the default Markdown representation;
- attachments do not need public sharing;
- authenticated Drive API access is used to load private attachment bytes.

Prefer a shared abstraction such as `VaultPathResolver` in `MarkdownDriveCore`.

Do not implement image upload/rendering during the text-only MVP unless explicitly asked, but avoid data models that assume every Vault item is Markdown text.

When attachment support is implemented later:

- preserve relative-link portability;
- prevent path traversal outside the Vault root;
- use collision-safe filenames;
- preserve unsaved Markdown text if upload fails;
- do not insert a Markdown link until upload succeeds;
- treat binary caching as disposable, not authoritative.

## Data-safety rules

These are non-negotiable:

1. Never silently overwrite a file that has changed remotely since it was opened.
2. Never discard a dirty editor buffer because refresh/network/authentication failed.
3. Never log OAuth tokens.
4. Never log document contents in production.
5. Use Google Drive Trash for delete behavior when possible.
6. Destructive folder actions require confirmation.
7. Saving must update the same Drive file rather than silently creating duplicates.

Implement conflict detection before considering autosave.

---

## OAuth rules

Before coding OAuth:

1. consult current Google primary documentation;
2. determine the minimum scope that satisfies automatic enumeration of all pre-existing descendants of a chosen folder;
3. document the chosen scope and its rationale in `docs/OAUTH.md`;
4. use a native/desktop OAuth flow appropriate for current Google requirements;
5. store refresh credentials securely in Keychain.

Do not solve scope limitations by asking the user to authorize every Markdown file individually. That violates the product requirement.

---

## Editor rules

MVP is a Markdown **source editor**, not a rich text editor.

Requirements:

- UTF-8;
- Japanese IME must work correctly;
- standard macOS editing commands;
- undo/redo;
- find;
- line wrapping;
- unsaved-change state;
- `⌘S` save.

Prefer a simple, robust native editor before adding syntax highlighting.

When modifying editor internals, manually test Japanese composition text before considering the change complete.

---

## UX rules

Use standard macOS patterns.

Recommended structure:

- sidebar: Drive folders and `.md` files;
- detail: editor;
- toolbar: new note, new folder, refresh, save status;
- Settings: account/Vault selection and minimal preferences.

Keyboard support is important.

Avoid custom visual design until the functional workflow is stable.

---

## Development sequence

Unless repository state suggests otherwise, work in this order.

### Milestone 0 — Project skeleton

- create macOS SwiftUI application;
- create/establish `MarkdownDriveCore` as a reusable local Swift package or equivalent shared module;
- establish module/folder structure that keeps macOS-specific UI outside the core;
- add test target;
- add basic domain models;
- ensure project builds and tests run.

### Milestone 1 — Google authentication

- implement OAuth;
- secure token storage;
- sign-in/sign-out;
- token refresh;
- fake auth service for tests;
- write `docs/OAUTH.md`.

### Milestone 2 — Drive read path

- Drive API client;
- folder browsing;
- select Vault root;
- recursively enumerate folders/files;
- paginate correctly;
- `.md` filtering;
- persist Vault ID;
- restore Vault at launch.

At the end of this milestone, all existing Markdown files in a test folder must appear automatically without per-file registration.

### Milestone 3 — Editor

- select a file;
- download contents;
- edit text;
- track dirty state;
- Japanese IME verification;
- current-file metadata tracking.

### Milestone 4 — Safe save

- `⌘S`;
- update same Drive file;
- save status;
- pre-save remote metadata check;
- conflict handling;
- network/error recovery.

Do not proceed to convenience features until safe save works.

### Milestone 5 — File operations

- new note;
- new folder;
- rename;
- trash;
- refresh.

### Milestone 6 — Polish and acceptance

- relaunch restoration;
- errors;
- loading states;
- accessibility labels;
- menu commands/shortcuts;
- manual acceptance checklist from SPEC.md;
- README setup instructions.

---

## Future platform constraints

While implementing macOS, avoid unnecessary dependencies on AppKit-specific concepts inside product logic.

When a platform-specific API is needed:

- define a small interface in shared code where useful;
- implement the macOS adapter in the macOS target;
- leave room for an iOS/iPadOS adapter later.

Examples include:

- OAuth presentation/session integration;
- secure credential storage wrappers;
- document editor implementation;
- keyboard/menu commands;
- window/navigation behavior;
- image/file pickers and drag/drop surfaces.

Attachment path resolution itself should remain shared.

Do not build placeholder iOS/iPadOS UIs during MVP.

The expected expansion order is:

1. finish and stabilize macOS;
2. add iPadOS using the shared core and split-view UX;
3. add iPhone with compact navigation.

## Testing expectations

For every service-layer feature, prefer automated tests with fake responses.

Minimum important tests:

- tree building;
- pagination;
- Vault boundary enforcement;
- extension filtering;
- authentication transitions;
- token-refresh failure;
- conflict detection;
- remote deletion;
- save failure retaining local text;
- rename behavior;
- trash behavior.

Do not make normal test execution depend on live Google Drive credentials.

If integration tests using a real Google account are added, keep them opt-in and clearly documented.

---

## Working style for Codex

Before each significant change:

1. inspect the existing code and tests;
2. state the small implementation goal;
3. implement the smallest coherent change;
4. run relevant tests/build;
5. fix failures before continuing.

Do not rewrite unrelated code.

Do not add dependencies unless they provide clear value that cannot reasonably be achieved with Apple/system APIs.

If adding a dependency:

- explain why;
- verify maintenance/activity;
- prefer small focused dependencies;
- avoid dependencies for trivial helpers.

---

## Documentation required before MVP completion

Maintain:

### `README.md`

Include:

- product purpose;
- prerequisites;
- Google Cloud configuration;
- how to run;
- how to choose a Vault;
- known limitations.

### `docs/OAUTH.md`

Include:

- OAuth client type;
- scopes;
- why each scope is needed;
- redirect flow;
- token storage;
- how to revoke credentials;
- any Google verification limitations relevant to personal/private use.

### `docs/ARCHITECTURE.md`

Include:

- major modules;
- Drive data flow;
- local state vs remote source of truth;
- conflict-detection strategy.

---

## Definition of done for every feature

A feature is not done merely because the happy path works.

For each feature consider:

- loading;
- empty state;
- error state;
- authentication expiry;
- remote mutation;
- Japanese input where applicable;
- accessibility;
- testability.

---

## Final MVP acceptance statement

Do not call the macOS MVP complete until this is true:

> A user can launch the app, sign into Google, choose a Drive folder once, automatically see every existing Markdown file below it, edit and save those files directly in Drive, create/rename/trash notes and folders, relaunch into the same Vault, and safely coexist with edits made from another device without silent data loss.
