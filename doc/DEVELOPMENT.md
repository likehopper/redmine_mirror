<!--
File: redmine_mirror/doc/DEVELOPMENT.md

Redmine Mirror - modular project import and asynchronous replication.
SPDX-License-Identifier: GPL-2.0-or-later

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 2 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE for details.

Document Mirror setup, operation, extension points or validation evidence.
-->

# Developing Redmine Mirror

To add a module, start with the [adapter tutorial](ADAPTERS.md) and its
[copyable example](examples/project_notes.rb).

## Architecture

| Object | Role |
| --- | --- |
| `Registry` | Validates registered adapters and resolves their phases and dependencies |
| `SourceCatalog` | Discovers remote references for the mapping forms |
| `MappingTable` | Lists available local choices; never creates administration-owned definitions |
| `Runner` | Plans and applies imports |
| `DatabaseStore` | Persists correspondences, fingerprints and diagnostics |
| `Synchronization` | Queues and leases project runs, runs preflight, writes filtered logs |
| Controllers | Authorize every action against the current project |

REST adapters create or update issues and time entries. Native-model adapters keep
historical metadata, import child objects and apply secondary issue state: they need
the configured local destination and cannot write to a remote host.

## Adapter passes

Categories and versions run before issues. Issues produce the IDs used by history,
files, time, hierarchy and relations. Parents and relations may point to other
projects, which are imported separately before the owning project is rerun. Preview
uses `planned:<source_id>` placeholders for objects not created yet; they are never
valid database IDs.

See [the adapter contract](ADAPTERS.md). Register new adapters in `lib/redmine_mirror.rb`,
and test project isolation, preview, native validations, conflicts and repeated imports.

## Code conventions

- English identifiers and comments. Explain invariants and reasons, especially for
  permissions, fingerprints, ordering, anonymization and recovery.
- Keep `frozen_string_literal` and shebangs first.
- Plugin-owned commentable files start with `File: redmine_mirror/<relative-path>` and
  `SPDX-License-Identifier: GPL-2.0-or-later`; paths follow the repository layout.
- Views use ERB comments for headers, so they render nothing.
- JSON, binary images, fixture bytes and the verbatim LICENSE stay unchanged; see
  [file-header exceptions](FILE_HEADERS.md). Keep third-party notices.
- Never log API keys, response bodies or private issue contents. Use native project
  authorization and reject identifiers from other projects in controllers.
- Preserve historical timestamps on purpose; send no notification during history imports.
- A new migration adding a column to `mirror_project_settings` also adds it to
  `MirrorProjectSetting::LATEST_COLUMNS`, so a forgotten `redmine:plugins:migrate` is
  explained on the configuration page.

## Verification

Run the standalone tests and the full Redmine suite described in the
[test environment guide](../test/environment/README.md). Browser tests cover mapping
forms, permissions and navigation with long translated labels. Check YAML/JSON parsing
and that view comments are absent from rendered HTML. When the UI changes, regenerate
the guide's screenshots with `bash test/documentation/run.sh`.

Record each tested Redmine/database combination in the validation record: the minimum
version declared in `init.rb` is not a compatibility claim.
