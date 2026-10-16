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
- SQLite/Redmine 6.1.4 is the current validated combination; see the compatibility matrix.
