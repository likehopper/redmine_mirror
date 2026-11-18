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
Current plugin version: **1.0.0-beta.50**.

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
| Any version | PostgreSQL / MariaDB / MySQL | Not validated |

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
