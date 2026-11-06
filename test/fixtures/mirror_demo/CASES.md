<!--
File: redmine_mirror/test/fixtures/mirror_demo/CASES.md

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

# Demo project cases

This page lists every case of the demo source project: what the source holds, what
Mirror must do with it, and which test checks it. The project is built by
[`generate.rb`](generate.rb); the [README](README.md) explains its files and how to add a case.

## The tests

Two test files read the project through `test/mirror_demo_source.rb`, which answers like
the source. A request the fixtures do not answer gets a 404 and is listed in
`unrecorded`. Both test files check that this list is empty, so every request Mirror
makes is covered.

| Test | Needs Redmine | Checks |
| --- | --- | --- |
| `test/mirror_demo_test.rb` | No | Reference catalog, source refusals, text formats, issue and time entry writes |
| `test/unit/mirror_demo_modules_test.rb` | Yes | Import by every module that writes locally, then a second pass with no change |

Run them from the plugin directory and from the Redmine root:

```sh
ruby test/mirror_demo_test.rb
bundle exec ruby -Itest plugins/redmine_mirror/test/unit/mirror_demo_modules_test.rb
```

### `mirror_demo_test.rb`

| Test | What it proves |
| --- | --- |
| `test_the_catalog_reads_every_module_of_the_demo_project` | The reference refresh reads every module; the record counts below match; 4 issues have a parent; 8 distinct tags |
| `test_the_catalog_keeps_the_source_refusals_and_text_formats` | Users' details refused (`not_shared`); user, tracker, status, activity and custom field names; detected formats: 20 Textile, 2 Markdown, 184 plain texts |
| `test_the_replay_answers_like_the_source` | 403 on categories and custom fields; issue details with one include; generated large files respect the size limit; unknown requests answer 404 |
| `test_every_issue_and_time_entry_builds_its_destination_write` | The 53 issues and 132 time entries convert into destination writes: UTC dates, mapped tracker, 8 versions, 1 private issue, one theme per subject; Bob's time goes to the anonymous user |

Record counts read by the catalog:

| Module | Records | Module | Records |
| --- | --- | --- | --- |
| Issues | 53 | Wiki | 12 |
| Time entries | 132 | Documents | 5 |
| Issue history | 141 journals | Files | 4 |
| Issue attachments | 23 | News | 4 |
| Issue relations | 6 | Tags | 53 issues |
| Issue categories | 4 | Agile sprints | 5 |
| Versions | 3 | Agile issue data | 53 |
| Members | 6 | Saved queries | 11 |

### `mirror_demo_modules_test.rb`

The destination is Redmine's test project 1. Every reference value maps to one local
value. The six source users map to six local users, two of whom are already members.
Each module imports, then runs again and must find everything unchanged.

| Test | First pass |
| --- | --- |
| `test_project_references_wiki_documents_files_news_and_queries` | Categories: 4 created. Versions: 3 created. Members: 4 created, 1 updated (role added), 1 unchanged. Wiki: 12. Documents: 5. Files: 4. News: 4. Saved queries: 7 created, 4 ignored. No mail sent; the titles with a number, an accent and an apostrophe exist |
| `test_issue_history_attachments_relations_hierarchy_and_watchers` | One local issue stands for each source issue, because the issues module writes through the REST API. History: 131 created, 10 ignored (relation changes only). Attachments: 23, the 5 MB file whole. Relations: 5 created, 1 ignored (project not mirrored). Hierarchy: 4 updated. Watchers: 3 issues updated |

## Source and references

| Case | Source data | Expected | Checked by |
| --- | --- | --- | --- |
| Default references plus extras | Redmine's trackers, statuses, priorities, activities, document categories and roles, plus two values per list except priorities | Every value is listed for mapping | Catalog names |
| Custom fields hidden from the reader | `custom_fields.json` answers 403 | Severity and Customer reference are read from the issues | Catalog names |
| Categories hidden from the reader | `issue_categories.json` answers 403 | The 4 categories are read from the issues, one of them from another project | Catalog count, module test |
| Users not shared | Mirror source answers `not_shared` | The Users tab shows why there are no details; mapping still works | `user_details_refusal` |
| User who left | Bob Former's account is locked | Mapped like the others; his time can go to the anonymous user | Time entry writes |
| Members with several roles | Alice is Reporter and Client | One membership with both roles mapped | Module test |
| Shared version | "Shared roadmap" belongs to the partner portal, shared with every project | Listed in the project's versions, not imported as a project version | Version count (3) |

## Issues

Each issue is one case, named in its subject. Numbers are source IDs.

### `[Text]` texts and formats

| # | Case | Source data | Expected |
| --- | --- | --- | --- |
| 1 | Textile: headings, lists, tables, code and links | Every common Textile markup | Detected as Textile, converted for the destination format |
| 2 | Markdown written in a Textile project | Markdown description in a Textile source | Detected as Markdown, not as Textile |
| 3 | Plain text, no markup | Lines without markup | Detected as plain text |
| 4 | Empty description | `""` | Imported with an empty description |
| 5 | Long subject with special characters | 255 characters, `<script>`, quotes, €, œ | Subject kept whole; HTML stays text |
| 6 | Accented characters | é è à ç ü ß ñ in the subject and description | Characters kept |
| 7 | Emoji in the description, not in the subject | Emoji in the description only (Redmine 4 MySQL subjects are 3-byte UTF-8) | Emoji kept |
| 8 | Very long description | About 65 KB of lorem ipsum | Imported whole |
| 9 | References to issues, notes, wiki pages, versions, files and the source | `#1`, `#1#note-1`, `[[Home]]`, `version:"Release 1.0"`, `document#1`, `news#1`, `attachment:`, `commit:`, an absolute source URL | References kept for the text conversion and link checks |
| 10 | Inline images: inline, aligned, sized and in a table | `!image!`, `!>image!`, `!{width: 50%}image!`, image in a table cell, 2 attachments | Images kept through the conversion |
| 11 | Image shown only in a note | The image is attached by the journal that shows it | The note and its attachment are imported |

### `[Files]` attachments

| # | Case | Source data | Expected |
| --- | --- | --- | --- |
| 12 | One attachment of each kind | 12 files: PNG, JPEG, GIF, SVG, PDF, DOCX, XLSX, ZIP, JSON, CSV, text, 1.2 MB photo | All imported with their content type, author and date |
| 13 | Large attachment (5 MB) | SQL dump declared by size | Imported whole, under the 32 MiB limit; the test checks its size |
| 14 | File names with spaces, accents and parentheses | `Quote (v2) 2026.pdf`, `meeting notes - café.docx`, `UPPER-CASE.PNG` | Names kept |
| 15 | Attachment added then removed | The history adds and removes `draft.csv` (deleted, no download) and adds `orders.csv` | The history keeps both changes; only the current file is downloaded |
| 16 | Same file name uploaded twice | Two `screenshot.jpg`, "Before" and "After" | Two distinct attachments |

### `[State]` fields and states

| # | Case | Source data | Expected |
| --- | --- | --- | --- |
| 17 | Private issue | `is_private`, Urgent, 2 watchers | Stays private (the only private issue) |
| 18 | Closed in a closed version | Closed, version Beta 0.9 closed, 100% | Closing date kept |
| 19 | In a locked version | Version Alpha 0.8 locked | Version assigned despite its state |
| 20 | In a version shared by another project | Version of the partner portal | The shared version must be found or imported first |
| 21 | Rejected | Rejected status, closing date | Closed status kept |
| 22 | Reopened after closing | New, Resolved, Closed, Feedback, In Progress; closing date kept | History in order, issue open |
| 23 | Moved from another project | History: `project_id` 2 → 1 | Imported in the project; the move stays in the history |
| 24 | Category of another project | Category "Partner API" | Category created or mapped |
| 25 | Assigned to a user who left | Assignee Bob (locked) | Assignee mapped or anonymized |
| 26 | Written by a user who left | Author Bob (locked) | Author mapped or anonymized |
| 27 | Unassigned, no category, no version | Only a subject and a text | Empty fields stay empty |
| 28 | Dates, estimate and progress | Start and due dates, 12.5 h, 60% | Values kept |
| 29 | Custom fields | Severity Major, Customer reference PO-2026-118 | Values imported to mapped fields |
| 30 | Extra tracker and status | Epic, On hold | Values to map, absent from Redmine's defaults |
| 31 | Extra status, priority Immediate | In review, Immediate, category API | Values to map |

### `[History]` journals

| # | Case | Source data | Expected |
| --- | --- | --- | --- |
| 32 | Every field changed | Subject, description, version, assignee, category, priority, status, dates, estimate | Each change in its journal with its author and date |
| 33 | Private notes | 2 public and 2 private notes | Private notes stay private |
| 34 | 100 notes in one issue | 100 journals by 4 users over 10 days | All imported in order |
| 35 | Note by a user who left | Note by Bob | Author mapped or anonymized |
| 36 | Note quoting another note, with a code block | `bq.` and `<pre>` | Markup kept |

### `[Tree]` hierarchy

| # | Case | Source data | Expected |
| --- | --- | --- | --- |
| 37–39 | Three levels: root, middle, leaf | 39 → 38 → 37 | Parents set after the issues exist |
| 40–41 | Subtask created before its parent | 40 has the higher-numbered 41 as parent; history sets the parent | Parent found although it comes later |
| 42 | Parent changed in the history | Parent 41 → 37 | Current parent 37; the change stays in the history |

The 4 issues with a parent are 38, 39, 40 and 42: the hierarchy module updates them, and
the other 49 stay unchanged.

### `[Links]` relations

| # | Case | Source data | Expected |
| --- | --- | --- | --- |
| 43 | Every relation type | relates #1, duplicates #3, blocks #19, precedes #28 with 2 days, copied to #44 | 5 relations created once, from either end |
| 44 | Copy of the relation hub | Other end of `copied_to` | Same relation, not duplicated |
| 45 | Related to an issue of another project | Relation to #944 in the partner portal, which answers 403 | Relation ignored until that project is mirrored |

Redmine records each relation as journals on both issues, with no note. The history
module ignores these 10 journals: the relations module imports the relations themselves.

### `[Watch]`, `[Time]` and `[Agile]`

| # | Case | Source data | Expected |
| --- | --- | --- | --- |
| 46 | Watched by four users, one of whom left | John, Alice, Bob, Paula | Mapped watchers added; issues 12, 17 and 46 are updated |
| 47 | Time by several users and activities | 4 entries: Design, Development, Testing, Project management | Each entry with its user and activity |
| 48 | Time by a user who left | 2 entries by Bob | Entries go to the mapped or anonymous user |
| 49 | 120 time entries | 120 daily entries of 0.25 h | The time list is read over two pages of 100 |
| 50 | Tags with accents, capitals and spaces | "Front end", "café", "URGENT" | Tags kept as written |
| 51 | In a sprint, with story points | Sprint 3, 5 points | Sprint and points imported |
| 52 | In a sprint of another project | Sprint 7, absent from the project's sprints | Handled without a matching sprint |
| 53 | Moved between sprints in the history | `sprint_id` 2 → 3, `position` 4 → 1 | History imported |

The project also has 3 time entries without an issue (steering meetings), and
issues 1, 17, 12 and 46 have tags too.

## Wiki

| Page | Parent | Versions | Case |
| --- | --- | --- | --- |
| Home | — | 3 | Start page, inline image, attachment |
| Documentation | Home | 2 | Intermediate level |
| Installation_guide | Documentation | 6 | Long history, attachment |
| Architecture | Documentation | 2 | Image added in a later version, 2 attachments |
| Technical_details | Architecture | 1 | Third level |
| Users'_guide | Documentation | 1 | Apostrophe in the title |
| Café_menu | Documentation | 1 | Accent in the title |
| Meetings_2026 | Home | 2 | Number in the title, not an ID |
| Markdown_page | Home | 1 | Markdown in a Textile wiki |
| Long_page | Home | 1 | About 45 KB |
| Renamed_page | Home | 2 | Text of a renamed page |
| Sandbox | — | 1 | No parent, 3 attachments |

Parents are imported before their children, and every version is imported with its
author and date. The module test finds the titles with a number, an accent and an
apostrophe.

## Documents, news and files

These modules read the source through Mirror source; their attachments download from
`mirror/source/attachments/<id>/download`.

| Item | Case |
| --- | --- |
| Document "Platform architecture" | Technical documentation, inline image, 2 files |
| Document "User guide" | Empty description, no file |
| Document "Steering committee minutes, 15 September" | Extra category Meeting minutes, DOCX |
| Document "Functional specifications" | Extra category Specifications, PDF and XLSX |
| Document "Document without files" | Description only |
| News "Project kick-off" | Image, 2 files, 2 comments, one of them by Bob |
| News "Version 0.9 released" | Empty summary, no comment |
| News "Planned maintenance on 12 October" | Comment by a user who left |
| News "News written in Markdown" | Markdown text, JPEG |
| Files "release-plan.txt", "deliverables.zip" | Files on the project |
| Files "release-notes.txt", "specification.pdf" | Files on versions Release 1.0 and Beta 0.9, with download counts |

## Saved queries

| # | Query | Case | Expected |
| --- | --- | --- | --- |
| 1 | Open bugs of version 1.0, mine first | Public; status, tracker, version, `me`; custom field column; sort; grouping | Created |
| 2 | My issues in progress (private) | Private; filter on a user ID | Created, user mapped |
| 3 | Alice's private query | Private query of another user | Created |
| 4 | Visible to developers | Visible to one role | Created, role mapped |
| 5 | High priority, open | Several priorities | Created |
| 6 | Subject contains export | Text filter, date column, sort | Created |
| 7 | Sprint 3 | Scrum filter | Ignored, no local equivalent |
| 8 | A named subproject | Subproject ID | Ignored, no local equivalent |
| 9 | Tagged URGENT | Tag filter | Ignored, no local equivalent |
| 10 | Development time this month | Time entry query, related field `issue.tracker_id` | Created |
| 11 | Kanban board | Agile board | Ignored, needs an agile plugin |

## Sprints

| Sprint | Case |
| --- | --- |
| Sprint 1 (1) | Closed, with an issue still open |
| Sprint 2 (2) | Locked and shared |
| Sprint 3 (3) | Open |
| Sprint 1 (4) | Same name as an older sprint |
| Product backlog (5) | Backlog: every issue without a sprint is here |
