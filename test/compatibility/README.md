<!--
File: redmine_mirror/test/compatibility/README.md

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

# Compatibility and publication checks

Minimum declared Redmine version: **5.0** as a destination, **4.0** as a source with
Mirror source (source only). This is not a compatibility certification.
Current plugin version: **1.0.0-beta.57**.

## 1.0.0-beta.57 validation — 2026-11-22

Candidate based on `v1.0.0-beta.56`: attachment preconditions checked before download,
subprojects summary in the Mirror source settings, interrupted reference refreshes
requested again, Getting started steps kept done during a refresh. No migration.

- `bash test/compatibility/run.sh` (same container script): Redmine 6.1.4 / Ruby 3.4.11 /
  Rails 7.2.3.2 / SQLite; standalone suites green; 394 Redmine tests, 2,370 assertions,
  no failures, errors or skips.
- Redmine 4.0.3 / Ruby 2.6.3 / MySQL 5.7 source-only suites (runner with `mysql2`
  pinned to the image's 0.5.2): API 36 tests, 197 assertions; settings 18 tests, 192
  assertions, including the new subprojects summary. Only the two failures known since
  beta.50 remain (document access log row count, administration session list).
- Not rerun for this candidate: PostgreSQL, MySQL, MariaDB, interinstance smokes,
  `versions.sh` and documentation guides.

## 1.0.0-beta.56 validation — 2026-11-22

Candidate based on `v1.0.0-beta.55`: the application key button of the Mirror source
settings submits its own POST form instead of the PATCH settings form.

- `bash test/compatibility/run.sh`: Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
  SQLite; 387 Redmine tests, 2,331 assertions, no failures, errors or skips.
- Redmine 4.0.3 / Ruby 2.6.3 / MySQL 5.7 source-only suites (runner with `mysql2`
  pinned to the image's 0.5.2): API 36 tests, 197 assertions; settings 17 tests, 174
  assertions, including the new key-form checks. Only the two failures known since
  beta.50 remain (document access log row count, administration session list).
- Not rerun for this candidate: PostgreSQL, MySQL, MariaDB, interinstance smokes,
  `versions.sh` and documentation guides.

## 1.0.0-beta.55 validation — 2026-11-22

Candidate based on `v1.0.0-beta.54` with bounded HTTP response bodies, source access
sessions kept distinct by account, address and purpose, SQL group counts, batched run
diagnostics and progress writes, project-scoped hidden-email fingerprints, normalized
source accounts and clarified native-API boundaries.

- `bash test/compatibility/run.sh`: Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
  SQLite; 387 Redmine tests, 2,327 assertions, no failures, errors or skips. The same
  runner passed the standalone suites, including core (64 tests, 248 assertions), HTTP
  client (12 tests, 66 assertions) and diagnosis (4 tests, 13 assertions), plus fresh
  install and uninstall/reinstall.
- Not rerun for this candidate: PostgreSQL, MySQL, MariaDB, Redmine 4 source-only,
  interinstance smokes, `versions.sh` and documentation guides. Their beta.54 results
  below are historical evidence for that exact source, not beta.55 validation.

## 1.0.0-beta.54 validation — 2026-11-22

Candidate based on `70ca7dc` (beta.53) with the source client authorization branch
merged (per-project client addresses, accounts and application key, migration 27,
metadata-only access logs, Mirror source project tab), the execution page in tabs with
causes and consequences, the access status of a source project and non-member
assignees restored locally. Runs on the committed candidate.

- `bash test/compatibility/run.sh`: Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
  SQLite; 385 Redmine tests, 2,317 assertions, no failures, errors or skips, plus the
  standalone suites (core: 64 tests).
- Redmine 6.1.4, isolated databases, unit, functional and integration suites:
  PostgreSQL 15, 373 tests, one failure also present in beta.50 (the `4.0` total);
  MySQL 8.0 and MariaDB 10.11, 363 tests, no failures, same strict SQL modes and the
  same three table-altering tests left out as for beta.51. These runs found two defects
  SQLite did not show, fixed before release: the refusal reason column was too short
  for `incremental_visibility` (widened by migration 27), and an administration sort
  test relied on the order of two equal counts.
- Migrations 26 and 27 down to 25 and up again on these three engines and on Redmine
  4.0.3 / Ruby 2.6.3 / MySQL 5.7.44, with a run journal written before migration 26.
- Redmine 4.0.3 / MySQL 5.7.44 source-only API and settings suites: 36 and 16 tests
  with two failures already present in beta.50.
- Not run: the documentation guides (`test/documentation/run.sh`, failing since beta.50
  on configuration steps 7 to 15), the interinstance smokes and `versions.sh`; no new
  screenshot of the execution page tabs or of the source access status.

## 1.0.0-beta.53 validation — 2026-11-21

Candidate based on `7893344` (beta.52): run log stored one row per object (migration
26), live progress per module, single pass with *Skip it*, simulation withdrawn from
the pages. Uncommitted working tree at the time of these runs.

- `bash test/compatibility/run.sh`: Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
  SQLite; 373 Redmine tests, 2,215 assertions, no failures, errors or skips, plus the
  standalone suites (core: 62 tests).
- Redmine 6.1.4, isolated databases, unit, functional and integration suites:
  PostgreSQL 15.19, 361 tests, one failure also present in beta.50 (the `4.0` total);
  MySQL 8.0.46 and MariaDB 10.11.19, 351 tests, no failures, with the same strict SQL
  modes and the same three table-altering tests left out as for beta.51.
- Migration 26 on these three engines and on Redmine 4.0.3 / Ruby 2.6.3 / MySQL
  5.7.44: a journal written before it (flags, error details, a textual wiki ID, a
  null destination) is moved into rows and the column emptied; down rebuilds the same
  JSON journal; up again keeps the rows.
- Redmine 4.0.3 / MySQL 5.7.44 source-only API and settings suites: 32 and 10 tests
  with three failures already present in beta.50.
- Two Redmine 6.1.4 instances (`compose.yml`, isolated project name): the incremental
  smoke passed (partial baseline, mapping-only retry, one source change read once),
  its applying runs now in one pass.
- Not run: the documentation guides (`test/documentation/run.sh`, already failing in
  beta.50 on configuration steps 7 to 15; their simulation steps were rewritten) and
  `versions.sh`. No screenshot of the live progress yet.

## 1.0.0-beta.52 validation — 2026-11-21

One destination change on beta.51: an HTTP 422 from a source's change journal (a source
up to beta.50 asking for its consumer key) selects the compatible mode, like a 404. The
standalone change-set test covers both statuses; the CI runner results are below.

## 1.0.0-beta.51 validation — 2026-11-21

Candidate based on `494b53f4b8a9ae20b55310f1abf9ca237e0a1cf1` (beta.50): Mirror source
security review, source without destination state (migration 25), visibility-filtered
change journal, wiki pages read from their index, session index (migration 24).

- `bash test/compatibility/run.sh`: Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
  SQLite; 371 Redmine tests, 2,205 assertions, no failures, errors or skips, plus the
  standalone suites, Chromium, fresh installation and uninstall/reinstallation.
- Redmine 6.1.4, isolated databases, unit, functional and integration suites:
  PostgreSQL 15.19, 359 tests, one failure also present in beta.50 (an administration
  total shown as `4.0` instead of `4`); MySQL 8.0.46 and MariaDB 10.11.19, 349 tests,
  no failures. MySQL and MariaDB sessions used `ONLY_FULL_GROUP_BY`,
  `STRICT_TRANS_TABLES` and `STRICT_ALL_TABLES`; their runs leave out the three tests
  that alter tables inside a transaction (`categories_test`, `project_enumerations_test`
  and the categories case of the source API test), which MySQL commits implicitly.
- Migrations 24 and 25 down to 23 and up again on the three Redmine 6.1.4 engines
  above and on Redmine 4.0.3 / Ruby 2.6.3 / MySQL 5.7.44 (SQLite: all plugin
  migrations down and up in the CI runner): consumer tables and the destination
  consumer key removed, session index present.
- Redmine 4.0.3 / Ruby 2.6.3, source-only API and settings suites: on SQLite, 35 and
  10 tests with the four failures already present in beta.50; on MySQL 5.7.44, 32 and
  10 tests with three of those failures.
- Two Redmine 6.1.4 instances (`compose.yml`, isolated project name): the incremental
  smoke passed with the source's dedicated read-only account: partial complete pass,
  targeted retry from the destination queue, one source change read once. The source
  kept no consumer data and refused no administrator key.
- Not passing, unchanged from beta.50: the configuration guide steps 7 to 12, 14 and
  15 (`test/documentation/run.sh`), and `versions.sh`, whose UI smoke still selects a
  module before saving the connection. Its cross-version incremental smoke assumes
  identical IDs and fails on mapped assignees. The source settings screenshot was
  regenerated; other screenshots are unchanged.

## Member aliases candidate validation — 2026-11-18

Unreleased working tree on `fix/member-aliases`, based on
`58db213e28150d55ee6aabb91212a7c3b5c11890` (beta.49). The behavior changes are the
Members batch preparation, scoped mapping uniqueness and migration 23, and shared
membership deletion handling. SHA-256 of the sorted relative path, NUL, content,
NUL concatenation of `app/models/mirror_mapping.rb`,
`db/migrate/023_allow_shared_member_destinations.rb`,
`lib/redmine_mirror/adapters/members.rb`, and `lib/redmine_mirror/runner.rb`:
`c66832938ecef249ea19d3aafe29913f5477442c2364fe4e31e64488c6a582f6`.

- `bash test/compatibility/run.sh`: Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
  SQLite; 357 Redmine tests, 2,106 assertions, plus 87 standalone tests and 383
  assertions. Includes Chromium and fresh installation/uninstall/reinstallation.
  An additional incremental-alias regression was added afterwards and passed with
  the targeted suites below; executable plugin source was unchanged.
- Redmine 5.1.13 / Ruby 3.2.11 / Rails 6.1.7.10, isolated databases: the Members
  suite passed 14 tests / 48 assertions and the Mirror mode suite passed 6 tests /
  15 assertions on each of PostgreSQL 15.19, MySQL 8.0.46, MariaDB 10.11.19 and
  SQLite 3.44.2. Both MySQL and MariaDB sessions had `ONLY_FULL_GROUP_BY`,
  `STRICT_TRANS_TABLES` and `STRICT_ALL_TABLES` enabled.
- The populated upgrade smoke below passed separately on all four engines: original
  rows are retained, other modules keep their destination uniqueness, downgrading
  with shared members is refused before schema changes, and a downgrade/reupgrade
  without aliases retains the original rows.
- PostgreSQL regression control: the alias import test fails with
  `ActiveRecord::RecordNotUnique` when the three beta.49 runtime files are restored,
  and passes with the candidate. No test failures, errors or skips in corrected runs.

From an initialized, empty, disposable Redmine test database, the targeted commands
are run from the Redmine root:

```sh
RAILS_ENV=test bundle exec ruby -Itest plugins/redmine_mirror/test/unit/members_test.rb
RAILS_ENV=test bundle exec ruby -Itest plugins/redmine_mirror/test/unit/mirror_mode_test.rb
RAILS_ENV=test MIRROR_TEST_ENVIRONMENT=disposable bundle exec rails runner plugins/redmine_mirror/test/compatibility/member_mapping_upgrade.rb
```

These are local tests, not a new release matrix. This candidate has not been
published, deployed, or verified through a real two-instance synchronization.
PostgreSQL 13 and source-only Redmine 4/MySQL 5.7 were not rerun.

## 1.0.0-beta.49 validation — 2026-11-17

The candidate based on `710bf052a7fa6d20d66c1bc06663f15390d1ec7e` passed
`bash test/compatibility/run.sh`: Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
SQLite, with 351 Redmine tests and 2,085 assertions, plus 87 standalone tests
and 383 assertions. No failures, errors or skips. The runner included Chromium,
fresh installation and uninstall/reinstallation. The final documentation and
README badge were updated after this run; executable source was unchanged.
PostgreSQL, MariaDB, MySQL and real interinstance synchronization were not rerun
for this candidate. Retained-cache limits do not establish process RSS or API-rate
gains on production-sized projects.

## 1.0.0-beta.48 validation — 2026-11-14

The candidate passed the Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
SQLite 3 plugin suite locally: 351 tests and 2,078 assertions, without failures,
errors or skips. The six standalone HTTP client tests also passed with 32 assertions.
The regression coverage verifies the native `updated_on` issue fallback, retrying
previous failures and preventing filtered results from implying deletions. Live
Redmine 4 / MySQL and Redmine 5 / PostgreSQL behavior must be verified separately
on the target environments.

## 1.0.0-beta.47 validation — 2026-11-14

The candidate passed the Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
SQLite 3 plugin suite locally: 350 tests and 2,074 assertions, including Chromium,
fresh installation and a 64-bit synthetic Wiki identifier, without failures, errors
or skips. Migration 22 still has to be exercised on the Redmine 4 / MySQL source and
Redmine 5 / PostgreSQL destination before this candidate is deployed there.

## 1.0.0-beta.46 validation — 2026-11-14

The candidate passed the Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
SQLite 3 runner locally: 349 tests and 2,077 assertions, including Chromium, fresh
installation, rollback/reinstallation and the standalone adapter suites, without
failures, errors or skips. The incremental protocol also passed a real two-instance
smoke from a Mirror source on Redmine 4.2.10 / Ruby 2.7.8 into this destination:
partial baseline, targeted retry after adding a missing mapping, one changed issue,
destination acknowledgement and no reproposal. The wider inter-version harness stopped
in Selenium before its other smokes; PostgreSQL, MariaDB and MySQL were not tested.

## 1.0.0-beta.45 validation — 2026-11-13

The exact candidate passed the Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
SQLite 3 runner locally: 343 tests and 2,056 assertions, including Chromium, fresh
installation, rollback/reinstallation and the standalone adapter suites, without
failures, errors or skips. PostgreSQL, MariaDB, MySQL and a real two-instance
synchronization were not rerun for this presentation-only correction.

## 1.0.0-beta.44 validation — 2026-11-12

The exact candidate passed the Redmine 6.1.4 / Ruby 3.4.11 / Rails 7.2.3.2 /
SQLite 3 runner locally: 342 tests and 2,048 assertions, including Chromium, fresh
installation, rollback/reinstallation and the standalone adapter suites, without
failures, errors or skips. PostgreSQL, MariaDB, MySQL and a real two-instance
synchronization have not yet been rerun for this candidate.

## 1.0.0-beta.43 validation — 2026-11-12

The exact candidate passed the complete Redmine 6.1.4 / Ruby 3.4.11 / Rails
7.2.3.2 / SQLite 3 runner locally: 331 tests and 1,985 assertions, including
Chromium, fresh installation, rollback/reinstallation and the standalone adapter
suites, without failures, errors or skips. The Localizable integration was exercised
with controlled settings, but was not browser-tested with an installed Localizable
plugin. No real two-instance synchronization smoke was rerun for these mapping and
catalog changes.

## 1.0.0-beta.42 validation — 2026-11-12

The exact candidate passed the complete Redmine 6.1.4 / Ruby 3.4.11 / Rails
7.2.3.2 / SQLite 3 runner locally: 326 tests and 1,965 assertions, including
Chromium, fresh installation, rollback/reinstallation and the standalone adapter
suites, without failures, errors or skips. Redmine Reporting 1.5.2 was also loaded
with this candidate on the same runtime: 142 tests and 1,323 assertions passed,
including the single Reporting module and mapping-page assertions. No real
two-instance synchronization smoke was rerun for this presentation/catalog change.

Destination (Redmine running Mirror):

| Redmine | Database | Evidence |
| --- | --- | --- |
| 6.1.4 | SQLite 3 | Official-image CI runner, locally and on GitHub: Ruby 3.4.11 / Rails 7.2.3.2, 195 Redmine tests / 1033 assertions, symlinked install, `zeitwerk:check`, fresh install and uninstall/reinstall. All two-instance smokes in production mode. |
| 5.1.13 | SQLite 3 | Two-instance write smokes in production mode (`versions.sh`). Full Redmine plugin suite run once locally on the `reporting-compat-ready:5.1.13` image (1.0.0-beta.18); not part of the CI runner. |
| 5.0 / 6.0 / 7.x | Not validated | No compatibility claim |
| 6.1.4 | PostgreSQL 15 / MySQL 8.0 / MariaDB 10.11 | Unit, functional and integration suites for 1.0.0-beta.53, isolated databases; no two-instance run |
| Other versions | PostgreSQL / MariaDB / MySQL | Not validated |

Source (read through its REST API; the Documents module needs Mirror on the source,
validated on 6.1.4 and, source only, on 4.0.3):

| Redmine | Evidence |
| --- | --- |
| 6.1.4 | All two-instance smokes |
| 5.0.12 | Write smokes into 6.1.4 and 5.1.13 destinations (`versions.sh`) |
| 4.2.10 | Write smokes into 6.1.4 and 5.1.13 destinations (`versions.sh`) |
| 4.0.3 | Write smokes into a 6.1.4 destination, without Mirror and with Mirror source only (Documents smoke, `MIRROR_SOURCE_PLUGIN=1 versions.sh`); install, uninstall and reinstall on Ruby 2.6.3 / Rails 5.2.3 |

The write smokes cover issues, time entries, categories and versions, history and
attachments, relations, hierarchy and watchers, custom fields, conflicts, locked users
and closed versions, the wiki, members and mirror mode; documents on the 6.1.4 stack. See the
[validation record](../environment/VALIDATION.md).

## Standalone CI runner

From the plugin root, with Docker installed:

```sh
bash test/compatibility/run.sh
```

It builds from the public official `redmine:6.1.4` image, installs Chromium and its
matching driver, and creates a fresh SQLite database inside a disposable container.
It requires no locally prepared Reporting image and exposes no service ports.
It also installs three test plugins, [`plugins/`](plugins), that add a project settings
tab with an `alias_method` chain (before and after Mirror) or `Module#prepend`, as
real-world plugins do (Smile, Reporting, SLA): the suite fails if the project settings
page or one of these tabs breaks.
It checks the actual Redmine version, runs standalone tests, fresh migrations,
uninstall/reinstall and the complete Redmine plugin suite including browser tests.
Build/run logs and failure screenshots are retained under a printed
`/tmp/redmine-mirror-compat.*` directory.

The GitHub workflow runs this command on pushes, pull requests and manual requests,
then stores diagnostics as artifacts. The same job builds a candidate archive from
its checked-out commit. It has read-only repository permissions and never publishes
or deploys a release. GitHub execution must be confirmed after the files are pushed.

## Wider validation

The independent [two-instance environment](../environment/README.md) covers actual
source/destination API imports with populated projects. The single-instance CI runner
uses API doubles in functional tests; it does not replace the interinstance smoke checks.
The older interactive demo build currently requires a prepared local Reporting image.

Add new Redmine/database combinations only after making the runner support them and
recording complete results. Worker concurrency and migrations on external databases
need dedicated tests. Keep released versions distinct from upstream development snapshots.
