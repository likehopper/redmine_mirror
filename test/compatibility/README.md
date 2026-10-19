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

Minimum declared Redmine version: **5.0**. This is not a compatibility certification.
Current plugin version: **1.0.0-beta.15**.

Destination (Redmine running Mirror):

| Redmine | Database | Evidence |
| --- | --- | --- |
| 6.1.4 | SQLite 3 | Official-image CI runner, locally and on GitHub: Ruby 3.4.11 / Rails 7.2.3.2, 140 Redmine tests / 630 assertions, symlinked install, `zeitwerk:check`, fresh install and uninstall/reinstall. All two-instance smokes in production mode. |
| 5.1.13 | SQLite 3 | Two-instance write smokes in production mode (`versions.sh`). The Redmine test suite is not run on 5.1. |
| 5.0 / 6.0 / 7.x | Not validated | No compatibility claim |
| Any version | PostgreSQL / MariaDB / MySQL | Not validated |

Source (read through its REST API only, Mirror not installed):

| Redmine | Evidence |
| --- | --- |
| 6.1.4 | All two-instance smokes |
| 5.0.12 | Write smokes into 6.1.4 and 5.1.13 destinations (`versions.sh`) |
| 4.2.10 | Write smokes into 6.1.4 and 5.1.13 destinations (`versions.sh`) |

The write smokes cover issues, time entries, categories and versions, history and
attachments, relations, hierarchy and watchers, custom fields, conflicts, locked users
and closed versions, the wiki, members and mirror mode. See the
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
