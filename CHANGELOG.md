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

- Texts are converted to the destination's text format (migration 010): descriptions,
  notes, description history and formatted long text custom fields. The source format is
  detected per text (Auto) or forced (Textile, Markdown, HTML), and the formats detected
  in the source are shown in the connection tab.

- Issue custom fields no longer need an administrator source key: without one, fields
  and values come from the source issues and history, each value takes the format of
  the mapped destination field and is validated in the preview.

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
