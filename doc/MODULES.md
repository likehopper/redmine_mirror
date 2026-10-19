<!--
File: redmine_mirror/doc/MODULES.md

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

# Module and operation reference

How each module behaves, and how runs, logs and conflicts work. For a first setup,
follow the [configuration guide](CONFIGURATION.md).

## Connection and references

An administrator sets the source URL, the source project (identifier or ID), the source API
key and the modules (**Mirror → Synchronization configuration → Connection**).
Selecting a module also selects the modules it depends on: *Time tracking* selects
*Issues*, and both select *Users*. Saving checks the connection and loads the source
references.

- Trackers, statuses, priorities and activities come from their source APIs. The forms
  list those the project's issues and history use, plus those already mapped.
- Users are discovered in the issues, time entries and watchers the API key can read.
- **Refresh source references** asks the worker to reload them, without changing any
  mapping; the worker handles it before any queued run. Each source issue is read once,
  with all its associations, for all modules.
- The source URL and project ID are locked once saved: changing the source will
  need an explicit reset, not available yet.

Mappings belong to the project. The user table is shared by all its modules.
Local choices are the project's members, locked ones included, and existing local
references. With the *Members* module, members managers (*Manage members*, or
administrators) choose among every active or locked account, as Redmine offers them
when adding a member; other users see the members and the accounts already mapped.
A local reference that disappears stays flagged in the form until replaced.

## Users and anonymization

*Users* only resolves identities: it never creates or modifies an account, so its
imported object count is always zero.

**Anonymize** a user to remove their identity from imported data:

| Data | Result |
| --- | --- |
| Issue assignee | Unassigned |
| Issue author, history, attachments | Redmine's built-in anonymous user |
| Time entries | The **local user for anonymized time** chosen in *Time tracking*; without it, the preview fails |
| Watchers | Not subscribed |
| User custom field values | Empty |

Anonymization covers user references only, not text content or names written in it.

**Locked users** keep the history of people who left: map a source user to their
locked local account. Without the *Members* module, it must still be a project member
(Redmine keeps memberships when an account is locked); *Members* can add it.

| Data | Locked user |
| --- | --- |
| Issue author, history, attachments | Kept |
| Issue assignee, time entries | Kept, restored through local models (the REST API refuses them) |
| Watchers | Not subscribed (a locked user receives no notification) |
| User custom field values | Not imported, with a warning (Redmine refuses them) |

## Members

Adds the source project's members to the destination project, with their own roles.
Runs before issues, so that assignees are members when issues are written. Requires
the source permission *View members* (public by default).

- Users go through *Users*; groups and roles have their own tables. Map each source
  group to an existing local group, or **Do not add this group**; map each role to a
  local role, or **Do not give this role**. Mirror creates no account, group or role.
- Additive: missing members and roles are added, local members and roles are kept,
  nothing is removed. A role Mirror gave and that was removed locally while the source
  still lists it is a conflict.
- Locked accounts can be added. Anonymized users are not added.
- Roles inherited from a group or a parent project are not copied: they come with that
  group or project.

## Issues

Copies subject, description, tracker, status, priority, assignee, privacy, category,
version, author and dates (`created_on`, `updated_on`, `closed_on`, at the API's
precision). Issues are created and updated through the destination REST API, so
native workflows and validations apply. Author and dates are then restored through
local models: the destination must be the Redmine the worker runs on
(`MIRROR_DESTINATION_URL`). Invalid dates or unmapped authors block the preview.

A locked assignee or a version that is not open (closed or locked), which the REST API
refuses, is left out of the API write and restored through local models, without a
journal. A version must belong to the project or be shared with it.

## Time entries

Copies hours, activity, date, comments, user and issue, through the REST API. The
destination API account must be allowed to log time for the mapped users. Time
logged on the project without an issue is imported too. Issues run first. Time of a
locked user is logged by the API account, then given back to that user locally.

## Categories and versions

Run before issues and create or update the local references; their correspondences
appear in **Object mappings**. Categories keep their name and assignee; versions keep
name, description, status, due date and sharing.

- A missing reference blocks the import; a local change is reported as a conflict.
- A version shared from another project must be imported in its owner project first.
- Existing local objects without a correspondence are never adopted; Redmine reports
  name collisions.

## Issue history and attachments

*Issue history* imports notes, private notes and field changes with their authors
and dates. Supported changes: simple fields, status, tracker, priority, user,
category, version and mapped custom fields. Other details (attachment and relation
changes, parent and project changes, categories or versions deleted since) are skipped:
the journal and its notes are still imported, and the execution log flags it. A journal
left empty is not imported. Unmapped statuses, trackers, priorities or users still fail
the journal. Imported journals send no notification.

*Issue attachments* copies the current files (up to the destination's maximum attachment
size, Administration → Files) with their
description, author and date. Downloads use a path built from the source URL: Mirror
never follows redirects or sends the key to a URL supplied by the source.

Both write through local models, so the worker must share the destination's database
and attachment storage. New source journals and files are added on later runs. A journal
or file changed on the source (an edited note, a text converted differently) is updated
locally when it was not changed locally. A local change is a conflict, or overwritten in
[mirror mode](#mirror-mode). REST updates also create local journals; they are kept.

## Issue relations

Run after issues. Keep each relation's type and delay. Endpoints are looked up in the
correspondences of every project mirrored from the same source URL, so a relation to
another project works once that project is imported.

For an endpoint not imported yet, the **Unsynchronized endpoint** option decides:

- **Ignore and log** (default): an `ignored` event in the log;
- **Add a private note**: a single private note with the relation and the remote link,
  without the target's subject. It stays in the history after the link is created.

Pending targets (`pending`) and rejected links (`blocked`) are listed in **Pending links**,
with source/local links, type, delay, reason and last check; **Overview** shows
their count. Import the target project, then rerun this one: projects never trigger
each other. A preview records nothing; an import updates the list, and removes relations
resolved or no longer returned by the source (never the imported native relations).

Cross-project relations require Redmine's *Allow cross-project issue relations*
setting on the destination. A native refusal, an ambiguous correspondence, a moved
local target or a local change blocks the run.

## Issue hierarchy

Links parents through correspondences, including parents imported by another project
from the same source. Redmine validates cycles and cross-project subtask rules.

An unimported parent is logged as `ignored` with its remote link and listed in the
**pending parents** table of **Pending links** (`pending`; `blocked` for links refused
during preflight). Import the parent's project, then rerun the child's. A local parent
change blocks the run.

## Issue watchers

Requires the source permission *View watchers list*; a response without `watchers`
blocks the run rather than meaning "no watchers". Refresh the references after enabling
it, to discover watchers who are not source project members, then map them in *Users*.

Mapped users must be able to see the issue, private ones included. Local subscriptions
are kept and new mapped watchers added; removals are not propagated. A local change to
an imported watcher list blocks the run.

## Text formats

Issue descriptions, notes, description changes in the history and long text custom
fields with full formatting are converted to the destination's text format (global, or
per project with redmine_per_project_formatting), using the destination Redmine's own
formatters: Textile and Markdown become HTML for CKEditor, HTML becomes Textile or
Markdown otherwise, and a text already in the right format is unchanged.

- **Auto** reads each text separately, so a source that changed format over time is
  handled. A text without recognizable markup is read in the project's dominant format
  (Textile or Markdown), else as Textile.
- Issue references (`#123`, `##123`, `###123`, `<source>/issues/123`) are rewritten to
  the destination issue. A reference to an issue not imported becomes a link to the
  source server; when that issue is imported later, a rerun points it to the destination.
  Issues imported later in the same run are handled by a second pass at its end.
  References in code (`@...@`, `<pre>`, backticks) are left as written.
- Other Redmine links and macros (`[[Wiki]]`, `{{toc}}`, `attachment:`) are kept as
  written; the destination interprets them when it displays the text. Inline images
  that name an attachment (`!image.png!`) still resolve to the imported attachment.
- Converted texts are what Mirror wrote: a rerun is unchanged, and a later local edit is
  a conflict as for any other field.

## Issue custom fields

Discovery lists the fields used by the project's issues and their history.

- With a **source administrator** key, Mirror also reads `/custom_fields.json`: formats,
  multiplicity and the complete lists of possible values are known and checked.
- Without one, Redmine hides the definitions. The fields and their values come from the
  issues and their history; each value takes the format of the mapped local field and is
  validated in the preview; list choices are the values actually found. The module tab
  says which mode applies.

1. Create the local fields in Redmine administration and enable them on the project and
   trackers. Mirror never creates field definitions.
2. In the module tab, map each source field to a local field, or **Ignore this field**,
   and save. Formats (when known) and multiplicity must match.
3. For list and key/value fields, map the values shown below the table and save again.
   Historical values still visible in the API are listed too.

Supported formats: string, text, integer, float, date, boolean, link, list, key/value,
user and version. User values go through *Users* (anonymized → empty). Version values
need *Project versions* and their owner project imported. Formats from other plugins
are refused.

Required fields are sent when the issue is created; later changes go through local
models with conflict checks. On the first run, an existing non-default local value is
not overwritten. A value Mirror cannot write (field not enabled for the project or the
issue's tracker, missing field or value mapping, incompatible format, invalid value) is
skipped with a warning, grouped by cause in the execution log: the issue, its time
entries and its history are still synchronized. A required destination field left
without a value makes Redmine reject the issue. An empty selection is a missing mapping; **Ignore this field**
excludes its values and history details but keeps the rest of each journal.

## Wiki

Imports the source wiki's pages into the destination project's wiki: every version
with its author, comments and date, the page creation date, parents and the current
attachments. Enable the Wiki module on the destination project first. Writes go through
local models and send no notification.

- Requires the source permissions *View wiki* and *View wiki history*. **Refresh source
  references** lists the authors of every version in *Users*.
- Local versions keep the source numbers; a version deleted on the source leaves the
  same gap. New source versions are added on later runs.
- Texts follow the destination format and issue references are rewritten, as for issues.
  Wiki links (`[[Page]]`) keep their titles, which are the same on both sides.
- A local edit of an imported page, or a local page with the same title but no
  correspondence, is a conflict.
- The API identifies a page by its title: a page renamed on the source is imported as a
  new page, and the old one stays. The start page and page protection are not copied.

## Synchronization and worker

**Run preview** and **Synchronize now** queue a run; the worker processes it. Every run
first validates all records (preflight), then writes. The preflight lists every failing
object, not only the first one. Progress counts processed objects, unchanged ones
included, and reaches 100% when the run ends.

**When an object fails** (Settings → Mirror → Automatic synchronization):

- *Skip it and synchronize the rest* (default): the failing object, and the objects that
  depend on it (its time entries, history…), are not written; everything else is. The run
  ends **Completed with errors**, and the next synchronization retries the skipped objects.
- *Stop: write nothing*: one failing object in the preflight leaves the destination
  unchanged; the run fails with the full list of errors.

Connection or configuration errors (unreachable source, invalid settings) always stop the
run.

Automatic synchronization is off by default. Intervals: 5, 15, 30, 60, 360 or 1440
minutes. The first deadline is set on save, and each finished run schedules the next:
missed deadlines do not trigger a burst. Disabling it cancels a queued automatic run,
not a running one.

The worker runs `rake redmine_mirror:tick` periodically. It needs the same database,
plugins, attachment storage and `database_cipher_key` as the web process, plus
`MIRROR_DESTINATION_URL` and `MIRROR_DESTINATION_API_KEY` in its environment. A database
lease prevents two runs of the same project, even across hosts.

On an unexpected error, the run stops, successful writes remain and the lease is released. A worker
crash can leave a run marked as running: it is not restarted, to avoid duplicate writes.
Check that the process has stopped and inspect the destination before recovering.

## History and logs

**Execution history** lists runs, filtered by status, mode, origin, module and creation
dates (user time zone, bounds included), with pagination. Each run log lists, per object,
the module, remote and local IDs with links, the action (`create`, `update`, `unchanged`,
`ignored`, `note`) and the reason, with filters and a count per module.

Logs never contain API keys or request bodies. They are kept without automatic purge.

**Object mappings** lists the project's persisted correspondences, filtered by module,
remote ID and local ID. Only imports create them; previews do not. On an imported issue,
users who can configure Mirror see a **Mirror source issue** link.

## Conflicts

Mirror stores a fingerprint of the managed fields of every imported object. When a local
value differs, the run stops at the first conflict, preview included, and records it in
**Conflicts** (module, remote and local IDs, reason, status).

- **Keep local object**: excludes this object, for this module and project only. The
  correspondence stays for dependencies; other modules (notes, attachments, watchers,
  custom fields) remain active. Each exclusion is logged.
- **Recheck after correction**: after fixing the data or the mappings, reopens the
  conflict for the next run. Fingerprints are not reset: a remaining difference blocks
  again. A successful import marks the conflict resolved.

Both require *Run Mirror synchronizations and resolve conflicts* and are refused while a run
is queued or running.
There is no field merge. [Mirror mode](#mirror-mode) overwrites local changes instead of
reporting them. This tracking applies to project runs (UI,
worker or `MIRROR_PROJECT_ID`), not to the standalone JSON mode.

## Mirror mode

**Settings → Mirror → Schedule → The source wins (mirror mode)** makes the destination a
copy of the source, for every selected module:

- A local change is overwritten by the source instead of being a conflict. A wiki page
  edited locally gets its source versions again; watchers and member roles become exactly
  the source ones (inherited roles excepted).
- An object deleted locally is created again.
- An object Mirror imported and the source no longer lists is deleted locally, once the
  source answers *not found* (404) for that very object. An object that moved to another
  source project, or that the source key can no longer see, is kept and logged.
- Up to 10% of a module's objects (at least 2) are deleted in a run. Beyond that, nothing
  is deleted: the run ends with errors, and **Overview** offers to synchronize again and
  confirm the deletions. The preview lists the deletions too.
- A version still used by local issues is not deleted; the log says so.

Deleting an issue also deletes its history, files, time entries, relations and subtasks,
as in Redmine. Local objects Mirror did not import are never deleted. Without mirror
mode, Mirror adds and updates only.

## Command-line runs

### Project mode

Runs the configuration saved in the UI, with the same lease, exclusions and logs. The
source key comes from the encrypted project settings:

```sh
MIRROR_PROJECT_ID=34 MIRROR_DESTINATION_URL=https://redmine.example \
MIRROR_DESTINATION_API_KEY=... RAILS_ENV=production bundle exec rake redmine_mirror:sync
```

This previews; add `APPLY=1` to write after checking the preview.

### Standalone JSON mode

For operator imports without UI configuration. Copy `config/mirror.example.json` to a
private file and fill in URLs, projects, modules and mappings: keys are source IDs,
values are destination IDs or `"anonymous"` for a user.
`module_options.users.anonymous_user_id` sets the account for anonymized time.
Pass keys through the environment, never in the file:

```sh
MIRROR_CONFIG=/private/mirror.json MIRROR_SOURCE_API_KEY=... MIRROR_DESTINATION_API_KEY=... \
  RAILS_ENV=production bundle exec rake redmine_mirror:sync
```

Add `APPLY=1` to write; the task previews everything again first. Correspondences are
tied to both URLs and projects: keep the URLs stable to resume without duplicates. The
lock is a local file, so run it on one host only. `allow_http: true` is for disposable
development environments.

## Limits

- One way only, from source to destination. Deletions are propagated in mirror mode only.
- Not a backup: data hidden from the source API key, instance configuration, accounts,
  roles and custom field definitions are not copied.
- Project files, SLA and Reporting adapters are not implemented yet.
- HTTPS with certificate checks is required; HTTP redirects are never followed.
- No transaction across API calls: an error keeps earlier writes, and an interruption
  between a creation and its correspondence can create a duplicate on resume. Inspect
  the destination before rerunning an uncertain write. No automatic HTTP retry.
- A concurrent edit after preflight can still be overwritten: the APIs offer no atomic
  version check.
- Preview checks mappings and conflicts but cannot guarantee that every write is accepted.
