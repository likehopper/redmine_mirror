<!--
File: redmine_mirror/ROADMAP.md

Redmine Mirror - modular project import and asynchronous replication.
SPDX-License-Identifier: GPL-2.0-or-later

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 2 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE for details.

Planned features, deferred designs and known issues still looking for a solution.
-->

# Roadmap

Ideas and open problems, not commitments: no dates, no fixed order. Shipped work is in
the [changelog](CHANGELOG.md).

## In progress

- **Ignore a source value.** A checkbox beside each mapping skips the dependent objects,
  logged as *ignored*, never as errors. Trackers are done (see *Unreleased* in the
  changelog). Still to do: statuses (issues), activities (time entries) and document
  categories (documents), on the same mechanism. Custom fields, roles and groups can
  already be ignored. Priorities stay mandatory. Users can be anonymized, not ignored.
- **Remap instead of ignore.** Send the issues of an unwanted tracker to another tracker,
  optionally keeping the source tracker name in a custom field.

## Planned features

### Agile data and tags

Through **Mirror source**, like Documents, once Documents are tested and
validated:

- **Agile data** (redmine_agile PRO). Sprints have no API key access and no read
  endpoint. Story points and board position are readable one issue at a time
  (`/issues/:id/agile_data.json`) and writable through `agile_data_attributes`, but the
  sprint of an issue is useless without the sprints themselves. Planned design:
  - Source: `GET projects/:id/mirror/source/sprints.json` returns the sprints (name,
    description, status, dates, sharing) with their issues and story points. A new
    shareable kind, *Sprints*, logged like Documents.
  - Destination: a *Sprints* module, offered only when redmine_agile and the agile module
    are enabled. Sprints are created before issues, like versions; issues are attached
    to their sprint once imported.
  - redmine_agile validations: names are unique per project, so an existing sprint with
    the same name is reused. Unshared sprints cannot overlap, so a conflicting sprint is
    logged as *ignored*. A sprint with open issues cannot be closed, so it is created open
    and gets its source status after the issues are attached.
  - Open questions: include story points (same `agile_data` row, almost free)? Separate
    beta?
- **Tags** (Redmine Tags plugin, Light version). Not exposed by the REST API, according to
  RedmineUP. Check the plugin source first.

### Smile project enumerations

Custom fields in the `project_enumeration` and `project_list_value` formats are rejected
today. The plugin has a full API for their per-project values: copy them and map them,
like versions.

### Subprojects

1. Add an **Include subprojects** option on the parent. It links the existing local
   subprojects by identifier or name, and lets them inherit the connection, modules, text
   format, mirror mode and mappings, each overridable per child. The tree runs in order,
   parent first, with a grouped log. Subprojects missing locally are listed, and an
   administrator creates them.
2. Later: create the missing subprojects automatically (an administrator option), and
   handle source subprojects that are deleted, archived or moved, in mirror mode.

What already exists: per-project configurations; issues exclude subprojects; relations,
parents and shared versions are resolved across other mirrored projects. The hard parts
are mappings shared across the tree and creating projects, which Mirror never does today.

### Shared source API key

The administrator sets a source API key in the plugin settings. Projects use it by
default, or are forced to use it. On the source, this means a single service account
with a read-only role, member of every project to synchronize. Forcing the source URL
needs no new setting: projects already choose from the allowed source URLs.

| Risk | Possible solutions |
| --- | --- |
| **Leak across clients.** The shared account sees every source project it belongs to, so the manager of destination A can enter the source project meant for client C. Separation then rests on Mirror alone. | Preferred: with the shared key, only an administrator picks the source project; managers keep modules, mappings and schedule. Alternative: one destination per source project through the shared key (weaker, first come first served). At least: a warning, acceptable only when all destination projects belong to one client. |
| Plugin settings are stored in clear in the database. | Encrypt the key with `Redmine::Ciphering`, as project keys already are. Never display or log it. |
| Revoking or rotating the key affects every project at once. | Projects reference the shared key and do not copy it, so a rotation applies everywhere. The admin overview shows which projects use the shared key and which use their own. Optionally, one key per allowed source URL instead of one global key. |
| The Mirror source access log shows the same user for every destination. | Send a header that identifies the destination project, and show it in the access log. |

Open question: does forcing the key also apply to administrators?

### SLA adapter

Most redmine_sla data (SLAs, types, levels, calendars, holidays, schedules) is defined
instance-wide in the administration, not per project. A per-project sync cannot copy it
cleanly: names collide, and the worker would need an administrator key. Decide first:
either move the SLA configuration into each project, or find a controlled way to
synchronize some administration data. Only the SLA project trackers are per project
today.

### AI proposals

- Propose correspondences for list values of custom fields, not only for references and
  users.
- AI explanations of Redmine validation errors were left out on purpose: their text can
  contain record data, which breaks the names-only rule in [AI usage](doc/AI.md). Revisit
  only with a way to send the error without its data.

### Objects not copied yet

To study. Checked against Redmine 6.1, the controllers that accept the API
(`accept_api_auth`).

With a REST API, not used by Mirror yet:

- **News.** Full API since Redmine 4.1, so every supported source has it. Author and
  creation date are probably those of the API account and of the import.
- **Files.** Read and upload API since Redmine 3.4 (`files#index`, `files#create`).
  Check whether it is enough before going through **Mirror source**, which is needed only
  to keep the original author or date.

Without a REST API, so through **Mirror source**, like Documents:

- **Forums**: boards, topics and replies. Nothing is exposed, read or write.
- **News comments.** News have an API, their comments do not.
- **Project time entry activities**: the activities enabled or disabled per project.
  `enumerations` only lists the global ones.
- **Wiki settings**: start page, redirects after a rename, protected pages, wiki
  watchers. The API covers only page contents and versions.
- **Watchers outside issues**: boards, topics and wiki pages. The `watchers` API covers
  issues only.
- **Reactions** (new in Redmine 6.1).
- **Saved queries.** Read only (`queries#index`): they cannot be created on the
  destination.
- **Repositories and changesets.** Only the links between a changeset and an issue have
  an API. Repository settings depend on the server: probably out of scope.

Plugins, besides agile data and tags: **Checklists** (RedmineUP, has its own API), and
**Contacts** or **Helpdesk** if clients use them.

### Other modules

- Copy document custom field values.
- Support the historical change types that are rejected today.

## Known issues to solve

| Issue | Current behavior | Direction |
| --- | --- | --- |
| No transaction across API calls | An error keeps the earlier writes. If a run is interrupted between creating an object and saving its correspondence, the resume creates a duplicate. | Record the intent before writing, then on resume find the created object (for example by a marker or by a search on its source ID) before creating it again. |
| No automatic retry | A temporary HTTP error fails the object or the run. | Retry idempotent reads with a backoff. Retry writes only when they cannot create a duplicate. |
| Concurrent edits | An edit made on the destination after the preflight can still be overwritten: the APIs offer no atomic version check. | Check again just before writing, and compare `updated_on` where the API returns it. Narrow the window, since it cannot be closed. |
| Preview is not a guarantee | Destination workflows and validations can still refuse a write that the preview accepted. | Extend the checks done before the preview (required fields, workflow transitions, enabled trackers) to catch more refusals in advance. |
| Flaky system test | `test_admin_configures_schedule_and_queues_preview` in `test/system/mirror_navigation_test.rb` sometimes fails with "Node with given id does not belong to the document", when the page reloads automatically. | Wait for the reload to finish, or pause the auto-reload in system tests. |
| Validation coverage | Validated only with SQLite, Redmine 6.1 and 5.1 as destinations, and 4.2, 5.0 and 6.1 as sources. | Add PostgreSQL and MySQL to the [compatibility matrix](test/compatibility/README.md). |
