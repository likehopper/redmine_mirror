<!--
File: redmine_mirror/test/environment/preprod/README.md

Redmine Mirror - modular project import and asynchronous replication.
SPDX-License-Identifier: GPL-2.0-or-later

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 2 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE for details.

Rebuild the Redmine 4 to Redmine 5 demonstration project on real preproduction servers.
-->

# Preproduction demo: Redmine 4 → Redmine 5

These scripts build the `mirror-demo` project used to validate Mirror on a real
Redmine 4.0.3 source (MySQL, Scrum, Redmine Tags, redmine_agile, local plugins) and a
Redmine 5 destination (PostgreSQL, CKEditor, redmine_agile PRO). Unlike the disposable
Docker environment of the parent directory, they run on servers that other people use:
each script touches only the demo projects and the demo accounts it creates, runs once
(a marker makes a second run stop), and sends no mail nor Mattermost message.

The demo data is in French, as the source server's users are: subjects, wiki titles with
accents and apostrophes, document categories that differ from the destination's.

## What each script adds

| Script | Server | Adds |
| --- | --- | --- |
| `01_source_seed.rb` | Redmine 4 | `mirror-demo` project, "Mirror reader" role and `mirror-reader` account (its API key is the destination's source key), Mirror source allowed and Documents shared; issues, time, wiki, files, documents |
| `02_destination_setup.rb` | Redmine 5 | `mirror-demo` project, source allowed, connection with the reader key read on STDIN |
| `03_source_edge_cases.rb` | Redmine 4 | `[Cas]` issues (inline images, varied files, Textile, references, private, versions, hierarchy, relations, full history), wiki edge cases, documents, the locked author Bob and the `mirror-demo-externe` project |
| `04_source_lorem_and_wiki_files.rb` | Redmine 4 | New versions and notes with lorem ipsum, files on every wiki page |
| `05_source_news.rb` | Redmine 4 | News with comments and files, shared |
| `06_source_tags.rb` | Redmine 4 | Issue tags (Redmine Tags), shared |
| `07_source_scrum.rb` | Redmine 4 | Scrum sprints and backlogs, positions, story points, shared |
| `08_source_queries.rb` | Redmine 4 | One saved query per rule of the Saved queries module, shared |
| `09_source_volume.rb` | Redmine 4 | `[Volume]` batch: 200 issues, about 600 time entries, wiki, news, documents, queries, edge cases (moved, reopened, 100 notes, 5 MB file, unmapped values) |
| `10_source_volume_history.rb` | Redmine 4 | The history of the volume batch (see below) |
| `11_source_personas.rb` | Redmine 4 | Personas: Alice the client, Bob the former developer, Tom a developer, Pierre the pilot |

## Run

```sh
bash test/environment/preprod/assets.sh            # demo files in /tmp/mirror-demo-assets
scp -r /tmp/mirror-demo-assets test/environment/preprod/0[13-9]_*.rb test/environment/preprod/1*.rb admin@source.example:/tmp/
ssh admin@source.example \
  'sudo -u redmine -H bash -lc "cd /var/www/redmine && MIRROR_DEMO_OWNER=jdoe RAILS_ENV=production bundle exec rails runner /tmp/01_source_seed.rb"'
```

Run the source scripts in their order, the same way. Then create the destination
project, passing the reader key without printing it:

```sh
scp test/environment/preprod/02_destination_setup.rb admin@destination.example:/tmp/
ssh admin@source.example 'sudo -u redmine -H bash -lc "cd /var/www/redmine && RAILS_ENV=production bundle exec rails runner \"puts User.find_by!(login: %q(mirror-reader)).api_key\" 2>/dev/null"' \
  | grep -oE '^[0-9a-f]{40}$' \
  | ssh admin@destination.example 'sudo bash -lc "cd /var/www/redmine && MIRROR_DEMO_OWNER=jdoe MIRROR_DEMO_SOURCE_URL=https://source.example MIRROR_DEMO_SOURCE_PROJECT_ID=42 MIRROR_DEMO_ROLES=Manager RAILS_ENV=production bundle exec rails runner /tmp/02_destination_setup.rb"'
```

The scripts need, in the environment of `rails runner`: `MIRROR_DEMO_OWNER` (login of an
existing account on both sides, author of most demo data) on every script,
`MIRROR_DEMO_SOURCE_URL` (source Redmine URL) for `03_source_edge_cases.rb` and
`02_destination_setup.rb`, and `MIRROR_DEMO_ROLES` (comma-separated roles given to the
owner on the destination) and `MIRROR_DEMO_SOURCE_PROJECT_ID` (numeric ID of the source
project) for `02_destination_setup.rb`. Select the later modules (News, Tags, Agile, Saved queries) in
`Settings → Mirror`, then map users and references as the run log asks.

## Pitfalls met on these servers

- Redmine 4 runs Ruby 2.6: no `filter_map`, `tally` nor endless methods in these scripts.
- `issues.subject` is 3-byte UTF-8 on the source: no emoji in subjects (descriptions
  accept them).
- A local plugin refuses time entries in validated months: historical entries are written
  without validation, as the history holds them. On the destination, administrators are
  exempt, so the worker's API account must stay administrator.
- In one transaction, Redmine 4 reuses the disk file of identical attachments after
  commit, and chained reuses leave files missing: the attachment scripts run without an
  outer transaction and repair any missing file.
- With the Scrum module enabled, Redmine 4 merges the journals one run saves on an issue:
  `10_source_volume_history.rb` writes the volume history directly.
- The source's global Mattermost webhook posts to a real server: the scripts stub its job.
- After changing Mirror on a server, restart its web service (`puma` on the source,
  `redmine` on the destination): the worker reloads the code, the pages do not.
