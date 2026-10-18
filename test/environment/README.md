<!--
File: redmine_mirror/test/environment/README.md

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

# Two-instance test environment

Two Redmine 6.1.4 instances with SQLite, their own volumes and an isolated Docker
network, plus a worker. It is meant for manual trials and real API checks between
instances. Its network cannot reach a production API.

The local base image `reporting-compat-ready:6.1.4` provides Chromium and its driver.
Without it, use the [standalone CI runner](../compatibility/README.md), built from the
official Redmine image.

## Start

From the plugin root:

```sh
docker compose -f test/environment/compose.yml up -d --build --wait
```

| Instance | URL | Content |
| --- | --- | --- |
| Source | http://localhost:3101 | `mirror-demo`: 12 issues, 13 time entries |
| Destination | http://localhost:3102 | `mirror-demo` with Mirror enabled |

Logins: `admin` / `Mirror-test-2026!` and `alice` / `Mirror-test-2026!`. These
credentials and API keys are fictitious and only valid here. Both instances are seeded
identically, so their references share the same IDs; real instances will not.

After changing the plugin, restart the destination to refresh its copy:

```sh
docker compose -f test/environment/compose.yml restart destination
```

`down` stops the stack and keeps the data; `down -v` also deletes this environment's
volumes. Volumes are never deleted automatically. Keep the stack name, or other volumes
could be reused.

## Configure in the UI

Open http://localhost:3102/projects/mirror-demo/settings/mirror and enter:

- source URL `http://source:3000`, source project `1`;
- API key: exactly 40 `1` characters.

Select the modules and save to get the mapping tabs. HTTP is accepted only because
this environment is declared disposable (`MIRROR_TEST_ENVIRONMENT=disposable`); the
cipher key is a test value.

A browser script can fill in the initial configuration and mappings, if the project
has no connection yet:

```sh
docker compose -f test/environment/compose.yml exec destination bundle exec ruby /mirror-environment/ui_smoke.rb
```

## Synchronize

From the UI: open the **Mirror** page
(http://localhost:3102/projects/mirror-demo/mirror),
click **Run preview**, then **Synchronize now**. The `worker` service processes queued
and scheduled runs: each cycle includes Rails startup and a 15-second pause.

```sh
docker compose -f test/environment/compose.yml logs --tail=100 worker
```

From the command line, with the mappings saved in the UI (add `-e APPLY=1` to write):

```sh
docker compose -f test/environment/compose.yml exec -e MIRROR_PROJECT_ID=1 \
  -e MIRROR_DESTINATION_URL=http://destination:3000 destination bundle exec rake redmine_mirror:sync
```

Without `MIRROR_PROJECT_ID`, the task reads the JSON configuration generated at
`/mirror-data/mirror.json` instead:

```sh
docker compose -f test/environment/compose.yml exec destination bundle exec rake redmine_mirror:sync
docker compose -f test/environment/compose.yml exec -e APPLY=1 destination bundle exec rake redmine_mirror:sync
```

Then check the destination: a second run returns `unchanged`; a subject changed on the
source is updated; a subject changed on the destination causes a conflict.

## Automated tests

Redmine functional and system tests (headless Chromium), on a database rebuilt each
time (`/mirror-data/automated.sqlite3`, separate from the manual one):

```sh
docker compose -f test/environment/compose.yml exec destination bash /mirror-environment/tests.sh
```

Standalone engine and HTTP client tests, from the plugin root:

```sh
ruby test/core_test.rb
ruby test/client_test.rb
```

## Fixtures

Seed scripts run on the source only and can be rerun without duplicates.
Redmine's own fixtures remain the basis of the automated suites.

| Script | Adds |
| --- | --- |
| `seed.rb` | Users, `mirror-demo`, 12 issues, 13 time entries; calls `enrich_source.rb` |
| `enrich_source.rb` | Per issue: public note (Alice), private note (admin), closing status change, text attachment with accents; 6 private issues, fixed dates (January 2026), one admin-authored issue to anonymize. Calls the two seeds below |
| `relations_seed.rb` | Subprojects `mirror-child-a/b`, project `mirror-independent`, two issues each, three cross-project relations and one internal *precedes* with a 2-day delay |
| `references_seed.rb` | A category and a version per project, used by each first issue; their changes in a child A journal; `mirror-unmapped-child` and `mirror-unmapped-project`, never mirrored |
| `issue_state_seed.rb` | `mirror-state-demo`, two subprojects, an independent and an unmapped project; internal, cross-project and unmirrored parents; watcher `mirror-observer` outside the project |
| `custom_fields_seed.rb` | `mirror-custom-fields-demo`: two issues (one private) and seven fields (required text, multiple list, integer, date, boolean, user, version), with history |

To enrich an existing source:

```sh
docker compose -f test/environment/compose.yml exec source bundle exec rails runner /mirror-environment/enrich_source.rb
```

After enriching, issues use the *Closed* status: map it in **Mirror → Issues**, or let
the browser script complete identical status mappings (demo only):

```sh
docker compose -f test/environment/compose.yml exec -e MIRROR_REFRESH_TEST=1 \
  -e MIRROR_COMPLETE_STATUS_MAPPINGS=1 destination bundle exec rails runner /mirror-environment/ui_smoke.rb
```

`MIRROR_ENABLE_HISTORY=1` on the same script enables history and attachments on the
manual project and anonymizes the source administrator.

Source and destination use distinct session and autologin cookie names, so both logins
can coexist on localhost. Log in again on each instance after this change.

## Smoke checks

Each check runs on the destination with
`docker compose -f test/environment/compose.yml exec destination bundle exec rails runner /mirror-environment/<script>`.
Unless stated otherwise, it imports into temporary projects and deletes them afterwards.

| Script | Checks |
| --- | --- |
| `smoke.rb` | Preview without writes, import, persisted correspondences (27 with categories and versions), idempotent rerun, local conflict. `MIRROR_PROJECT_CONFIG_SMOKE=1` uses the UI mappings |
| `synchronization_smoke.rb` | Browser preview and import, worker logs, simulated automatic deadline, no duplicates, next deadline |
| `history_smoke.rb` | 36 dated journals (12 private), 12 files, authors and dates against the source API, private issue visibility, rerun, local change refused |
| `relations_smoke.rb` | Missing targets, private notes without duplicates, late target import, reuse from the other side, delays, categories and versions, translated journal changes, blocked/resolved tracking, native cross-project setting refusal (restored afterwards) |
| `issue_state_smoke.rb` | Hierarchy and watchers: two passes, out-of-project watcher, preview, idempotence |
| `custom_fields_smoke.rb` | Seven formats, required field without local default, history, privacy, preview, idempotence, local change refused; temporary fields deleted |
| `conflicts_smoke.rb` | Conflict recorded, local object kept with its correspondence, recheck, correction and resolution |
| `relations_ui_smoke.rb` | Relation policy saved per project, pending list and counter in Chromium; policy restored |

Source fixtures for hierarchy and custom fields stay available at
http://localhost:3101/projects/mirror-state-demo and `mirror-custom-fields-demo`. For a
manual trial, create a destination project, select the modules, enter the source project
ID shown by the source API, then refresh the references.

## Older source versions

Mirror reads the source only through its REST API, so the source can run an older
Redmine. `versions.sh` starts a separate, disposable stack with the official image of the
source and a destination on a local `reporting-compat-ready:<version>` image, then runs
the write smokes. Stop the main stack first: both publish ports 3101 and 3102.

```sh
bash test/environment/versions.sh redmine:4.2 6.1.4
bash test/environment/versions.sh redmine:5.0 6.1.4
bash test/environment/versions.sh redmine:4.2 5.1.13
```

IDs differ across versions: the browser setup maps references by name and anonymizes
the source administrator, and `smoke.rb` uses those UI mappings. The stack and its
volumes are deleted at the end.

## Text formats

`formats/` provides a Redmine 4.2 source with CKEditor and per-project formatting, seeded
with Textile, Markdown and CKEditor projects (`formats_seed.rb`), and a destination built
on `redmine-mirror-test:<version>` (from `versions.sh`) with a CKEditor plugin supplied
from outside this repository:

```sh
MIRROR_CKEDITOR_PATH=/path/to/redmine_ckeditor bash test/environment/formats/formats.sh 5.1.13
```

`formats_smoke.rb` imports the three projects into a CKEditor destination with the source
format on *Auto*, checks the stored HTML, notes, formatted custom field and attachment,
then the rendering in Chromium.

## Reporting adapters

Mount a redmine_reporting checkout on both instances with the extra Compose file:

```sh
export MIRROR_REPORTING_PATH=/path/to/redmine_reporting
docker compose -f test/environment/compose.yml -f test/environment/compose.reporting.yml up -d --build --wait
bash test/environment/reporting_smoke.sh
```

At each start, the source gets `mirror-reporting-demo` (own settings, Support and Feature
credit policies with refills) and `mirror-reporting-child`, which inherits them.
`reporting_smoke.sh` imports into a temporary project: modules and tracker mappings in the
UI, preview without writes, worker import, object links, unchanged rerun. It then changes
the source, checks the update, changes a local policy and keeps it through the
**Conflicts** tab. The temporary project is deleted and the source data reset.

## Persistent demonstrations

These scripts keep their projects for manual trials.

`relations_demo.rb` creates the three extra projects on the destination, enables
relations on the main project, allows cross-project relations and runs two passes.
**Mirror → Issue relations** then shows two pending relations, and **Synchronization**
their count.

`conflicts_demo.rb` creates a `conflict-demo-*` project, imports the issues and edits
three local subjects without changing their dates. It prints the **Conflicts** tab URL
and saves the original subjects to `/mirror-data/conflict-demo-<project_id>.json`;
automatic synchronization stays off. Try **Keep local object** and **Recheck after
correction**: a recheck fails while the difference remains.

`tabs_ui_smoke.rb` checks that the tabs fit at 800, 1280 and 1920 pixels and that the
three conflicts are listed. Pass the identifier printed by `conflicts_demo.rb`:

```sh
docker compose -f test/environment/compose.yml exec -e MIRROR_CONFLICT_DEMO_PROJECT=conflict-demo-XXXXXXXX \
  destination bundle exec rails runner /mirror-environment/tabs_ui_smoke.rb
```

Screenshots are saved to `/mirror-data/mirror-tabs-<width>.png` and
`/mirror-data/mirror-conflicts-demo.png`.
