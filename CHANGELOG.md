<!--
File: redmine_mirror/CHANGELOG.md

Redmine Mirror - modular project import and asynchronous replication.
SPDX-License-Identifier: GPL-2.0-or-later

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 2 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE for details.
-->

# Changelog

## Unreleased

- **Files** module: the files of the source project's Files module are imported on the
  project or on their version, with their description, author, date, content and download
  count, through Redmine's REST API (*View files*; no Mirror source needed). A file whose
  version is not imported yet waits for the next run, logged as ignored. A description or
  version changed on the source updates the local file in place; mirror mode propagates
  deletions.
- Once source URLs are allowed in the plugin settings, every project chooses its source
  from that list, administrators included; another URL is refused. While the list is
  empty, administrators can still enter any URL.
- **Ignore a tracker**: in the tracker mappings, **Do not import its issues** leaves the
  source issues of that tracker out of the import. They are logged as ignored, not as
  errors, and so are their history, time entries, attachments, watchers, custom values,
  relations and parent links; a waiting relation or parent link to them is dropped.
  Statuses can be ignored the same way, activities (**Do not import its time entries**)
  and document categories (**Do not import its documents**) too. Priorities must be
  mapped.
- In the mapping tabs, *Anonymize* and the ignore choices are a checkbox beside the
  field, which it greys, instead of an entry of the list.
- **Show: to map / mapped / all** filters the mapping tables; the references to map
  are shown first.
- Long mapping tables, such as users, load and search much faster: the local choices
  are sent once per table, the search shows the first 50 matches, and same-name
  proposals no longer compare every row with every local reference.

## 1.0.0-beta.20 — 2026-10-20

- **Guidance** through the migration. The Mirror page lists what to settle before the
  preview: references without correspondence, disabled project modules, mapped fields
  the project does not use. A local tracker, status, custom field, activity, priority
  or user with the source name that is not offered in the project (not enabled, no
  workflow, inactive, not a member) is pointed out with the page that enables it. In
  the log, errors are grouped by cause, largest first, each explained with the fixes the
  current user may apply, or who to ask. A version inherited from a parent project names
  its source project and links to the local project mirroring it: synchronize it first.
- **AI proposals for the mappings**, optional and off by default (migration 016). An
  administrator sets the provider (Google Gemini, Ollama or another OpenAI-compatible
  API), an encrypted write-only key, the model (light models first) and a daily request
  limit in **Administration → Mirror → AI**. In a mapping tab, a table with enough
  references to map offers **Propose with AI**: the worker sends the names only, as the
  person who asked, and the proposals are preselected, never saved. A quota, credit or
  key refusal pauses AI until the connection is tested again. User names need a
  separate option. Rules in [doc/AI.md](doc/AI.md).
- Same-name proposals now ignore accents, punctuation and word order: *Dupont, Jérôme*
  proposes *Jerome Dupont*.

## 1.0.0-beta.19 — 2026-10-20

- **Documents** module: title, description, category, creation date and files with their
  authors and dates, without notifications. Categories are mapped to local document
  categories. Conflicts, mirror mode and deletions work as for the wiki.
- **Mirror source**, for a Redmine that is the source of a Mirror destination: Redmine has
  no documents REST API, so Mirror installed on the source serves them, read-only. Three
  locks, closed by default: the administrator allows Mirror source (plugin settings),
  the project enables the **Mirror source** module, and its **Settings → Mirror source**
  tab checks what it shares (Documents; Files later). The API key needs an account with
  *View documents*; anonymous requests are refused. Document files go through Mirror
  source too, not the attachments API.
- Every access is logged on the source, grouped by session (one per destination run or
  reference refresh, with its purpose): account, address, documents listed, files sent
  and refusals, in the project's tab and, for all projects, in Administration → Mirror.
  Retention defaults to 180 days (migration 015).
- The destination shows the requirement next to the Documents module and reports which
  lock to open when the source refuses. The other modules still need nothing on the
  source.
- **Administration → Mirror** gains a sidebar, as in Redmine SLA: **Destination:
  mirrored projects** (the former overview) and **Source: shared resources**. The latter
  shows whether Mirror source is allowed, the projects that enabled it with what they
  share, their last access and sessions, and the sessions of every project, filtered by
  project or to those with refusals, each with its details. The plugin settings keep
  the switch and the retention, with a link to this page.

## 1.0.0-beta.18 — 2026-10-20

- With *Skip it and synchronize the rest* (the default), a preview with errors ends
  **Partial** instead of **Failed**: a few objects that cannot be mapped no longer block
  the synchronization of the rest. *Stop: write nothing* keeps the former behavior.
- **Administration → Mirror**: the projects Mirror is configured in, as a Redmine query
  with filters, columns, grouping (root or parent project, source Redmine, mirror mode,
  status…), sorting, totals and CSV export: configuration, activity (running, last run,
  duration, message) and load (runs, recent runs, durations, objects, mappings,
  conflicts, pending links). Run durations are now stored (migration 014).

## 1.0.0-beta.17 — 2026-10-20

- Long choice lists no longer suggest *To configure*: clearing the field leaves the
  reference unmapped. Before, clearing it restored the previous choice.
- *Anonymize*, *Do not give this role*, *Do not add this group* and *Ignore this field*
  come first in the choice lists, before the local records.
- Members: *Roles and groups without a mapping* can be *not given* instead of blocking
  their members; they then leave the tab counter.
- A module tab warns when the Redmine module it needs (Issue tracking, Time tracking,
  Wiki) is disabled on the project, with a link to enable it. Tabs with nothing to
  save (Wiki, hierarchy, watchers) no longer show a Save button.

## 1.0.0-beta.16 — 2026-10-19

- User mappings show the login, email and company of each local account, and the list
  search covers them. The company is a user custom field chosen in the plugin settings
  (by default Company, Société or Entreprise). Redmine's visibility rules apply: login
  for administrators, hidden emails for administrators only.

## 1.0.0-beta.15 — 2026-10-19

- New **Members** module: adds the source members (users, locked accounts, groups) to
  existing local accounts and groups, with mapped roles, before issues. Additive; a role
  Mirror gave and that was removed locally is a conflict. With this module, members
  managers choose among every account of the destination in the user mappings.
- New **mirror mode** (*The source wins*, per project): local changes are overwritten,
  local deletions recreated, and source deletions propagated once the source confirms
  each object; beyond 10% of a module, deletions wait for a confirmation (migration 013).
- In every mode, a note or file changed on the source and not locally is updated, instead
  of blocking the run. A note or file deleted locally is a conflict, no longer an
  internal error.
- Text format detection: Textile block signatures (`h1.`, `bc.`, `p.`…) decide over
  backticks, `## ` lines and pipe tables.

## 1.0.0-beta.14 — 2026-10-18

- Locked users can be mapped: authors, history, attachments, assignees and time
  entries of people who left keep their account. Locked watchers are not subscribed; a
  user custom field value naming a locked user is skipped with a warning.
- Issues on a closed or locked version are imported: the version is set locally, as
  the REST API refuses it. A version not shared with the project now fails the preview.
- New **Wiki** module: pages with every version (source numbers, authors, comments,
  dates), parents and attachments, without notifications. A local edit is a conflict;
  a page renamed on the source is imported as a new page.

## 1.0.0-beta.13 — 2026-10-18

- Fixed: with a plugin that extends the project settings tabs through `alias_method`
  (such as Smile's project enumerations plugin), the project settings page failed with
  an internal error since 1.0.0-beta.12. Mirror adds its tab without patching
  Redmine's `ProjectsHelper`. The CI now installs plugins of that kind to catch it.
- The **Conflicts** tab lists the open conflicts by default; the filter offers the other
  statuses and *All*, and keeping or rechecking a conflict returns to the same filter.

## 1.0.0-beta.12 — 2026-10-18

The configuration moves to the project settings and the Mirror menu becomes the
operations page. No migration; former Mirror links lead to their new place.

- **Settings → Mirror** holds the connection, the automatic synchronization and one
  mapping tab per module. A red counter on a module tab gives the references it still
  has to map. A source reference with a single local namesake is preselected (yellow):
  check it, then save.
- The **Mirror** menu shows **Overview** (getting started until a first synchronization,
  source, schedule, preview and synchronize buttons, current execution, items to check,
  recent executions), **Execution history**, **Conflicts** with the number of open ones,
  **Pending links** (relations and parents) and **Object mappings**. Pages with a catalog
  refresh or an execution in progress refresh themselves.
- Three permissions: *View Mirror* (status, history, logs, conflicts), *Run Mirror
  synchronizations and resolve conflicts*, and *Configure Mirror*. Members who can enable
  the project's modules can also configure Mirror. Roles with the former *Configure
  Mirror mappings* keep all their rights; *View Mirror* now also shows the history and
  logs.
- Project members can now set the connection, but only to a source Redmine an
  administrator allowed in the plugin configuration; administrators can enter any URL.
- The execution log links an error to its fix only for members who can make it.

## 1.0.0-beta.11 — 2026-10-18

- Issue references in descriptions, notes and history (`#123`, `##123`, `###123` and
  links to `<source>/issues/123`) point to the corresponding destination issue. A
  reference to an issue not imported becomes a link to the source server; one to an
  issue imported later in the same run is rewritten by a second pass at the end of it.
  Code blocks are left untouched. The execution log flags both cases.
- More errors and warnings in the execution log link to where they are fixed: custom
  field enabled for the tracker or the project, value mappings, maximum attachment size,
  conflicts.
- Journals written by Mirror no longer send notifications.

## 1.0.0-beta.10 — 2026-10-18

- Watchers added locally, including those Redmine subscribes automatically (issue authors
  and the API account that writes issues), are no longer reported as local modifications:
  only a mirrored watcher removed locally is a conflict. Existing false conflicts clear at
  the next run.
- Error causes that differ only by the source object ID are grouped in the execution log.

## 1.0.0-beta.9 — 2026-10-18

- A custom field value Mirror cannot write (field not enabled for the tracker or project,
  missing field or value mapping, incompatible format, invalid value) no longer blocks
  the issue, its time entries and its history: the value is skipped and the execution
  log lists **Warnings by cause**, with a filter per warning.

## 1.0.0-beta.8 — 2026-10-17

- In the execution log, a cause in **Errors by cause** lists only its objects, and a
  missing mapping shows the source reference name with a link to the tab that fixes it.
- History no longer fails a whole journal on a detail it cannot translate: attachment and
  relation changes, parent and project changes, deleted categories or versions are
  skipped, the journal and its notes are imported, and the log flags it.
- Attachments follow the destination's maximum attachment size instead of a fixed 32 MiB.
- A custom field not enabled for a destination tracker is named, with the tracker.
- The worker explains pending migrations instead of failing on a missing column.

## 1.0.0-beta.7 — 2026-10-17

- Saving the connection or refreshing the source references no longer reads the source
  in the web request, which took minutes on large projects and timed out behind a
  proxy: the worker refreshes the references (migration 012) and the configuration page
  shows the refresh state.
- The configuration page shows the refresh step, module and records read, and a running
  preview shows how many objects it has checked.
- Each source issue is read once, with all its associations, for every module of a run
  or a refresh, instead of once per module.
- Markdown detection ignores constructs Textile and plain text share ("- item" lists,
  "> " quotes, `**bold**`), which classified Textile sources as Markdown.

## 1.0.0-beta.6 — 2026-10-17

- The preview lists every failing object instead of stopping at the first one. When an
  object fails, a new setting (migration 011) either skips it and its dependants and
  synchronizes the rest (default, run **Completed with errors**), or writes nothing.
- The execution log summarizes actions per module, groups errors by cause and flags the
  special cases to check: converted texts, issue numbers, links to the source Redmine,
  images and links to attachments, with a filter to list them.
- Plugins installed through a symbolic link (Capistrano-style `shared/plugins`) are no
  longer loaded twice, which caused "already initialized constant" warnings and could
  lose adapters registered by other plugins. The CI installs Mirror that way.

## 1.0.0-beta.5 — 2026-10-17

- Issue categories used by the project's issues but owned by another source project
  (moved issues, plugins) are created in the destination project, instead of blocking
  the preview with "Missing category correspondence".
- A missing category or version correspondence names the source issue and reference.
- Pending Mirror migrations are explained on the configuration page instead of an error.

## 1.0.0-beta.4 — 2026-10-17

- Texts are converted to the destination's text format (migration 010): descriptions,
  notes, description history and formatted long text custom fields. The source format is
  detected per text (Auto) or forced (Textile, Markdown, HTML), and the formats detected
  in the source are shown in the connection tab.

- Issue custom fields no longer need an administrator source key: without one, fields
  and values come from the source issues and history, each value takes the format of
  the mapped destination field and is validated in the preview.
- Not converted yet: links to the old server's attachments and issues, `#123` issue
  numbers (they keep the source numbers) and CKEditor (Rich) images stored outside
  Redmine attachments.

## 1.0.0-beta.3 — 2026-10-17

- A queued execution can be cancelled from the Synchronization tab or its log, and a
  warning appears when no worker has picked it up after 5 minutes.
- The Synchronization tab shows the start and end dates of the execution it displays.

## 1.0.0-beta.2 — 2026-10-17

- The source project can be entered by identifier as well as by numeric ID (migration 009).
- Mapping forms list only the source trackers, statuses and priorities used by the
  project's issues and history, plus those already mapped; local statuses are limited
  to the project's tracker workflows.
- Long choice lists, such as users, can be filtered by typing.
- A dedicated read-only source account is enough except for custom fields: categories
  fall back to those the issues use, and API errors name the refused request.

## 1.0.0-beta.1 — 2026-10-16

First public pre-release, for testing before 1.0.0. No stable release has been published yet.

### Features

- Project-scoped connection settings, encrypted source credentials and reference mappings.
- One-way issue and time-entry synchronization with preview and manual/automatic execution.
- Categories, versions, private issues, historical authors and dates.
- Notes, supported historical field changes and attachments.
- Cross-project relations and hierarchy, with pending/blocked diagnostics.
- Watchers and compatible existing custom fields, including mapped list values.
- Source/local object links, filtered execution history, progress and conflict exclusions.
- English/French UI and wrapping module navigation.
- Adapter tutorial, copyable example and executable tests.

### Fixes

- Boot in production: the version moves from `lib/redmine_mirror/version.rb`, which
  Redmine's eager loading rejected, to `lib/redmine_mirror.rb`. The CI runner now runs
  `zeitwerk:check`.

### Extension contract

- Adapter API version 1: `RedmineMirror.register_adapter`, validated module keys,
  declared execution phases, availability checks, adapter-provided object links and
  optional module partials, so other plugins can ship their own adapters.
- Modules whose plugin was removed or is unavailable stay visible in the configuration
  and block runs instead of being silently skipped.

### Publication preparation

- Central version metadata, contribution/security policies and GitHub issue/PR templates.
- Reproducible candidate packaging and a standalone Docker-based CI runner.
- Compatibility claims restricted to explicitly validated combinations.

### Documentation

- English-only documentation: illustrated configuration guide, module reference,
  test environment guide and validation record.
- `test/documentation/run.sh` regenerates the guide's screenshots in a disposable
  container with a seeded source Redmine.

### Known limitations

- No project/account/custom-field definition creation, propagated deletion or forced overwrite.
- Wiki, project files and SLA adapters are not implemented. Reporting settings and
  credit policies are provided by redmine_reporting when both are installed.
- Some historical detail types fail explicitly.
- HTTP writes and mapping persistence are not atomic; interrupted imports require inspection.
- Validated with SQLite only: destinations Redmine 6.1.4 and 5.1.13, sources Redmine 4.2,
  5.0 and 6.1; see the compatibility matrix.
