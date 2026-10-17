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
