<!--
File: redmine_mirror/doc/CONFIGURATION.md

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

# Configuration guide

From an installed plugin to a first synchronization, in twelve steps. Everything
happens on the **destination** Redmine; the source only needs its REST API and an API
key. Module details are in the [module reference](MODULES.md).

Mirror has two places in a project:

- **Settings → Mirror**: the configuration (connection, automatic synchronization, one
  mapping tab per module), for members allowed to configure Mirror;
- the **Mirror** menu: the operations (getting started, launching, execution history,
  conflicts, pending links, imported objects).

The screenshots come from the browser test
[`configuration_test.rb`](../test/documentation/configuration_test.rb). It mirrors the
*mirror-demo* project of a seeded source (12 issues with notes, attachments, a category,
a version and relations to other projects) into an empty *Mirror Demo* project. That
disposable setup uses HTTP; real installations require HTTPS.

## 1. Check the installation

`Administration → Plugins` lists **Redmine Mirror**. If not, see
[Installation](../README.md#installation).

![Plugin list](screenshots/configuration/01-admin-plugins.png)

## 2. Enable the REST API

`Administration → Settings → API`: tick **Enable REST web service**, on both the source
and the destination. The worker writes issues and time entries through the destination
API.

![REST API setting](screenshots/configuration/02-rest-api.png)

The source API key determines what can be imported: data it cannot see is skipped.
Use the key of a dedicated, non-administrator source account, member of the source
projects with a read-only role:

| Source permission | Needed for |
| --- | --- |
| View issues, issues visibility **All issues** | Issues, private issues, history, relations, hierarchy, versions |
| View private notes | Private notes |
| View spent time, visibility **All time entries** | Time tracking |
| View watchers list | Watchers |
| View wiki, View wiki history | Wiki |
| View members (public by default) | Members |
| View documents | Documents ([Mirror source](#mirror-source-on-the-source-redmine) on the source) |
| Manage issue categories (optional) | Category default assignees; without it, categories come from the issues that use them |

Projects the account is not a member of are not visible. **Issue custom fields** also
work without an administrator key: Redmine then hides the field definitions, so the
fields and their values come from the source issues, each value takes the format of
the destination field you map it to and is checked in the preview, and list choices
are the values found in the issues and their history. An administrator key adds
format compatibility checks and the complete lists of possible values.

## 3. Allow the source Redmine

`Administration → Plugins → Redmine Mirror → Configure`: list the source Redmine URLs,
one per line. Project members can connect only to these sources; administrators can
enter any URL. **User company field** picks the user custom field shown as the company
in the user mappings (by default, a field named Company, Société or Entreprise).
Optional AI proposals for long mapping lists are set in **Administration → Mirror → AI**:
see [AI usage](AI.md).

![Allowed sources](screenshots/configuration/03-allowed-sources.png)

## 4. Grant the permissions

`Administration → Roles and permissions → <role>`, **Mirror** block:

| Permission | Allows |
| --- | --- |
| **View Mirror** | Mirror menu: status, execution history and logs, conflicts, pending links, objects |
| **Run Mirror synchronizations and resolve conflicts** | The above, plus preview, synchronize now, cancel a queued run, keep or recheck a conflict |
| **Configure Mirror** | The above, plus the **Settings → Mirror** tab: connection, schedule and mappings |

Members who can enable the project's modules (*Select project modules*) can also
configure Mirror.

![Role permissions](screenshots/configuration/04-role-permissions.png)

## 5. Enable the module

`Project → Settings → Project`: tick **Mirror** under **Modules**, then save. Keep
*Issue tracking* and *Time tracking* enabled for the modules you import.

![Project modules](screenshots/configuration/05-project-modules.png)

The **Mirror** tab appears in the project menu.

![Project menu](screenshots/configuration/06-project-menu.png)

Until a first synchronization, it shows **Getting started**: each step, its state, and
a link to the page of the next one.

![Getting started](screenshots/configuration/07-getting-started.png)

## 6. Connect the source

**Connect the source project** opens **Settings → Mirror → Connection**:

- **Source Redmine URL**: one of the allowed sources;
- **Source project**: its identifier, as in `<source>/projects/<identifier>`, or its numeric ID;
- **Source API key**: stored encrypted and never displayed again;
- **Source text format**: *Auto* detects Textile, Markdown or HTML (CKEditor) for each
  text; choose a format to force it. Texts are converted to this Redmine's text format,
  and issue references point to the imported issues; the detected formats are shown
  after saving;
- **Modules** to import. Dependencies are added on save: *Time tracking* adds *Issues*,
  and both add *Users*.

![Connection](screenshots/configuration/08-connection.png)

Saving checks the connection; the worker then loads the source references, which can
take a few minutes on large projects. The page shows its progress and refreshes until
it has finished. The URL and project cannot be changed afterwards. **Refresh source
references** reloads them after new users, statuses or activities appear on the source.

A red counter on a module tab gives the number of references it still has to map.

![Modules to map](screenshots/configuration/09-modules-to-map.png)

## 7. Map users

**Users** lists the users found in the source data. Map each one to a member of the
project, locked accounts of people who left included, or **Anonymize** them. With the
**Members** module, members managers can choose any account of this Redmine. Each local
account shows its login (to administrators), email (unless hidden, except to
administrators) and company; typing in the list searches all of them. Time
logged by an anonymized user goes to the **local user for anonymized time**: here the
source administrator is anonymized and a dedicated *Mirror Archive* member receives
that time.

![User mappings](screenshots/configuration/10-users.png)

Mirror never creates accounts: add the missing members to the project first. The user
table is shared by every module.

## 8. Map the references

Each module tab lists the source references it needs. **Issues** maps trackers,
statuses and priorities. Only the references used by the source project's issues and
their history are listed, plus those already mapped; a link shows the others. Local
statuses are limited to those of the project's tracker workflows. Long lists, such as
users, can be filtered by typing.

A reference without correspondence is marked in red. When a single local reference has
the same name (ignoring case, accents, punctuation and word order), it is preselected and
marked in yellow: check it, then save. With [AI proposals](AI.md) enabled, a table with
many references without correspondence offers **Propose with AI**: the proposals are
preselected the same way, marked *proposed by AI* with a confidence.

![Issue mappings](screenshots/configuration/11-issues.png)

**Time tracking** maps activities.

![Time tracking mappings](screenshots/configuration/12-time-tracking.png)

Save each tab. A reference left unmapped (an empty field, or **To configure** in short
lists) stops the objects that use it.

**Issue relations** also chooses what to do when the other end of a relation is not
imported yet: log it, or add a private note with the remote link.

![Relation policy](screenshots/configuration/13-relations-policy.png)

## 9. Run a preview

On the **Mirror** page, **Overview** shows the source, the modules, the schedule, the
current execution and what needs checking. Click **Run preview**.

![Overview](screenshots/configuration/14-overview.png)

The run is queued, then processed by the worker (see [Run the worker](#run-the-worker));
the page refreshes until it finishes. The log lists what an import would do, object by
object, without writing anything.

![Preview log](screenshots/configuration/15-preview-log.png)

Before the first preview, the **Mirror** page lists what the configuration alone
reveals: references without correspondence, disabled project modules, mapped fields the
project does not use. A local reference that exists in Redmine under the same name but is
not offered (a tracker not enabled in the project, a status no workflow uses, an inactive
activity, a user who is not a member) is pointed out with the page that enables it.

![Before the preview](screenshots/configuration/35-checklist.png)

In the log, errors are grouped by cause, the largest first: fixing one unblocks all its
objects. Each cause is explained, with links to where it is fixed when the current user
may do it (a mapping tab, the project settings, a custom field, a workflow, a conflict),
otherwise who to ask. A version inherited from a parent project points to the local
project that mirrors that parent: synchronize it first.

![Errors by cause](screenshots/configuration/36-guided-errors.png)

Errors do not block the rest: with **Skip it and synchronize the rest** (the default), a
preview with errors ends **Partial**, and a synchronization writes every other object.
The failing ones are retried by the next synchronization. With **Stop: write nothing**,
the preview ends **Failed** and nothing is written until every error is fixed.

## 10. Synchronize

Click **Synchronize now**. The log gives, for each object, its remote and local IDs with
links, and the action taken. Its **Summary** counts the actions per module, groups the
errors and warnings by cause, and lists the **special cases to check**: converted texts,
issue numbers, links to the source Redmine, images and links to attachments. Click one
to list the objects concerned, each with its local and source links. The preview shows
them too, before anything is written.

![Import log](screenshots/configuration/16-import-log.png)

Once a synchronization has succeeded, **Overview** no longer shows Getting started.

![After the import](screenshots/configuration/17-overview-done.png)

**Object mappings** lists every remote/local correspondence.

![Object mappings](screenshots/configuration/18-object-mappings.png)

Imported issues keep their author, dates, notes and attachments. Members who can view
Mirror see a **Mirror source issue** link.

![Imported issue](screenshots/configuration/19-imported-issue.png)

Relations and parents in projects not mirrored yet wait in **Pending links**. Import
those projects, then synchronize this one again.

![Pending links](screenshots/configuration/20-pending-links.png)

## 11. Schedule automatic runs

In **Settings → Mirror → Automatic synchronization**, tick **Enable automatic
synchronization**, choose a frequency (5 minutes to 1 day) and what to do when an object
fails, then save. The next execution date is displayed.

Tick **The source wins (mirror mode)** for an exact copy: local changes are overwritten,
local deletions recreated and source deletions propagated (see the
[module reference](MODULES.md#mirror-mode)). Leave it unticked when the project is also
worked on locally: local changes are then reported as conflicts.

![Schedule](screenshots/configuration/21-schedule.png)

**Execution history** lists every run, with filters by status, mode, origin, module and
date.

![Execution history](screenshots/configuration/22-history.png)

## 12. Handle conflicts

Mirror never overwrites a local change. Here, a destination user edited an imported
issue's subject: the next run leaves it unchanged and reports it.

![Run with a conflict](screenshots/configuration/23-conflict-log.png)

**Conflicts** lists the object and the reason; its tab shows the number of open ones.

![Conflicts](screenshots/configuration/24-conflicts.png)

- **Keep local object**: excludes this object from this module, then synchronize again.
- **Recheck after correction**: after restoring the data or fixing a mapping.

![Conflict kept locally](screenshots/configuration/25-conflict-kept.png)

## 13. Follow usage and load

`Administration → Mirror` has two pages in its sidebar: **Destination: mirrored
projects** (below) and **Source: shared resources**
([Mirror source](#mirror-source-on-the-source-redmine)). The first lists the projects
Mirror is configured in, as a Redmine query:
filters (module, mirror mode, activity, last status, last run date, conflicts…), columns,
grouping (root or parent project, source Redmine, status…), sorting, totals and CSV
export. Columns cover the configuration (modules, mirror mode, schedule), the activity
(running or queued, last run, last success, duration, message) and the load (runs,
recent runs, total and average duration, objects processed, mappings, conflicts).

![Administration overview](screenshots/configuration/26-admin-overview.png)

## AI proposals (optional)

For long mapping lists, an administrator can enable AI proposals in
**Administration → Mirror → AI**: provider, key, model and daily limit. **Test the
connection and list the models** checks the key without spending credit. See
[AI usage](AI.md) for the rules and the data sent.

![AI settings](screenshots/configuration/32-ai-settings.png)

A mapping table with enough references without correspondence then offers
**Propose with AI**, with the number of requests it needs.

![Propose with AI](screenshots/configuration/33-ai-offer.png)

The worker asks the AI; the proposals are preselected in yellow, marked *proposed by
AI* with a confidence. Check them, then save.

![AI proposals](screenshots/configuration/34-ai-proposals.png)

## Mirror source (on the source Redmine)

Only for the **Documents** module, which Redmine's REST API does not provide. On the
source Redmine:

1. Install Redmine Mirror 1.0.0-beta.19 or later and run its migration (see the README).
   Nothing else of Mirror needs configuring there.
2. `Administration → Plugins → Redmine Mirror → Configure`: check **Allow Mirror
   source**. Off, nothing is shared, whatever the projects check.

   ![Mirror source allowed](screenshots/configuration/27-source-allowed.png)
3. In the project: `Settings → Modules`, enable **Mirror source** (the **Mirror** module
   is not needed), then in `Settings → Mirror source` check **Documents** and save.

   ![Shared data](screenshots/configuration/28-source-sharing.png)
4. Give the source API account *View documents* in that project. Anonymous access is
   refused, even on public projects.

The **Access log** below the sharing lists one session per destination run or reference
refresh: account, address, purpose, documents listed, files sent and refusals. **Details**
lists each request and what it sent. Refused requests name the lock that refused them.

![Access log](screenshots/configuration/29-source-log.png)

![Session details](screenshots/configuration/30-source-session.png)

Entries are kept 180 days by default (plugin settings). Configuring the sharing and
reading the log need the permission *Configure Mirror source and read its access log*.
`Administration → Mirror → Source: shared resources` shows whether Mirror source is
allowed, the projects that enabled the module with what they share, their last access
and sessions, then the sessions of every project, filtered by project or to those with
refusals, each with its details:

![Mirror source activity](screenshots/configuration/31-source-activity.png)

## Run the worker

Runs are processed by the worker, a command scheduled every minute on the destination
server (cron, systemd timer). It needs the same database, plugins, attachment storage and
`database_cipher_key` as Redmine:

```sh
MIRROR_DESTINATION_URL=https://redmine.example MIRROR_DESTINATION_API_KEY=... \
  RAILS_ENV=production bundle exec rake redmine_mirror:tick
```

`MIRROR_DESTINATION_API_KEY` belongs to a destination account allowed to create issues,
log time for the mapped users and perform the workflow transitions. Without the worker,
runs stay **Queued** and block new ones: after 5 minutes the **Overview** warns about it,
and **Cancel this execution** withdraws a queued run.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No **Mirror** menu | Step 5, then *View Mirror* (step 4). |
| No **Mirror** tab in the project settings | *Configure Mirror* (step 4). |
| "This source Redmine URL is not allowed" | An administrator adds it to the allowed sources (step 3). |
| "A trusted HTTPS Redmine URL is required" | Use an `https://` URL without credentials, query or fragment. |
| "Configure database_cipher_key…" | Set `database_cipher_key` in `config/configuration.yml`, then restart. |
| A reference is missing in a table | **Refresh source references**; check what the source API key can see. |
| A local user is missing from the choices | Add them to the project, or select **Members** and map them as a user with *Manage members*. |
| Run stays **Queued**, "already queued or running" | The worker is not running: schedule `redmine_mirror:tick`, or cancel the run in **Overview**. |
| "HTTP 403 for GET …" | The source account lacks the permission for that request (step 2). |
| "The source Redmine does not list documents" | Install Redmine Mirror 1.0.0-beta.19 or later on the source and restart it. |
| "Mirror source is disabled…", "Enable the Mirror source module…", "Share Documents…" | Open that lock on the source: [Mirror source](#mirror-source-on-the-source-redmine). |
| "MIRROR_DESTINATION_URL is not configured" | Set both variables in the worker's environment. |
| Preview ends Partial or Failed on a mapping | Complete the module tabs with a red counter (steps 7 and 8); with *Skip it*, the rest is synchronized meanwhile. |
| Run reports a conflict | Step 12. |
| Relations or parents pending | Import the other project, then rerun this one. |

## Regenerating the screenshots

```sh
bash test/documentation/run.sh
```

It runs the test in a disposable container (Redmine 6.1.4, SQLite, Chromium), with a
seeded source Redmine on the side. It updates `doc/screenshots/configuration/` and the
README image. The test is not part of `redmine:plugins:test`.
