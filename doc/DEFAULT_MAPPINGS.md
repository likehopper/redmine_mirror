<!--
File: redmine_mirror/doc/DEFAULT_MAPPINGS.md

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

# Default correspondences

When many projects come from the same source Redmine, they need the same
correspondences: *Feature* → *Requirement*, *Haute* and *Urgente* → *High*, every retired
status → *Archived*. An administrator sets them once in
**Administration → Mirror → Default correspondences**; each project then starts with
them. Covered by `test/integration/mirror_default_mappings_test.rb`.

![Default correspondences](screenshots/configuration/39-default-mappings.png)

## Rules

- **Per table**: trackers, statuses, priorities, activities, document categories, roles,
  groups and custom fields. A default gives one or more source names the same local
  reference, or the table's special choice (*Do not import its issues*, *Ignore this
  field*…). Names are compared ignoring case, accents, punctuation and word order.
- **Fallback**: a default without a source name takes every reference the project uses
  that has neither a default nor a single local namesake (the namesake stays a
  suggestion in the form). Users only take a fallback, such as a generic account (it need
  not be a project member) or *Anonymize*: accounts are matched in each project.
- **Custom field list values**: for a local list or key/value list field, the local value
  of source values, with a fallback too. They apply to every source field mapped to that
  field, for example *10 - Duplicate* → *Duplicate*.
- **Per source**: a default may be limited to one source Redmine URL; it then wins over
  the default for any source.

## When they apply

Each time a project reads its source references (saving the connection, **Refresh the
source references**), every reference still without correspondence that a default
covers gets it. The correspondence is saved in the project, marked *administrator
default* in the module tab, where it can be changed like any other. Defaults never
replace a saved correspondence, so changing a default later does not change the
projects already configured. A default the project cannot use (a tracker not enabled
in it, a field not available) is left for a person to map.

**Apply to configured projects** fills the projects already connected from the source
references they read last, without reading the sources again.

## CSV

**Export CSV** writes every default; **Import CSV** reads the same columns, separated by
`;`, `,` or a tab, in UTF-8 with a header line:

| Column | Content |
| --- | --- |
| `type` | `tracker`, `status`, `priority`, `activity`, `document_category`, `role`, `group`, `custom_field`, `user` or `custom_field_value` |
| `source_name` | The source name; empty for the fallback |
| `source_url` | Optional: the source Redmine the default is limited to |
| `destination` | A local name, a login, `#ID`, `ignore` or `anonymous`; for a value, its label |
| `custom_field` | For `custom_field_value` only: the local list field |

```csv
type;source_name;source_url;destination;custom_field
tracker;Feature;;Requirement;
priority;Haute;;High;
status;;;Archived;
role;Former reader;;ignore;
user;;;#12;
custom_field_value;10 - Duplicate;;Duplicate;Resolution
```

Every line is checked first: on any error (unknown type, destination or value, the same
name twice) nothing is imported and the errors are listed with their line numbers. A
line with the type, source URL and name of an existing default replaces it.

## Limits

- A source reference that changes kind (a source priority becoming a local custom field,
  or the reverse) is not a correspondence: it needs a transformation, not covered here.
- Field settings after an import (required again, *For all projects* unchecked) stay
  manual.
