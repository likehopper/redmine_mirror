<!--
File: redmine_mirror/doc/ADAPTERS.md

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

# Create your own Mirror adapter

Start with the [copyable REST example](examples/project_notes.rb): **five methods**,
with pagination, reads, defaults and conflict fingerprints inherited, and no controller,
migration or view to write. Mirror does not load it, and its notes API is fictional.

## 1. Check that the API fits

The simplest adapter needs this contract on both Redmine instances:

| Operation | Example contract |
| --- | --- |
| Read project | `GET projects/<id>.json` returns `{"project":{"id":42}}` |
| List records | `GET project_notes.json?project_id=42&offset=0&limit=100` |
| Read one record | `GET project_notes/7.json` returns `{"project_note":{...}}` |
| Create | `POST project_notes.json`, body `{"project_note":{"project_id":84,"title":"...","body":"..."}}` |
| Update | `PUT project_notes/900.json`, same entity wrapper |

The list response must contain the collection name and pagination count:

```json
{
  "project_notes": [
    {"id": 7, "project": {"id": 42}, "title": "Runbook", "body": "Restart procedure"}
  ],
  "total_count": 1
}
```

IDs are stable and numeric, and every record has `project.id`. A successful POST
returns the created entity with its ID. The destination GET returns every field listed
in `fields`, normalized the same way on every read.

Mirror sends authentication and project filters, checks project ownership and handles
pagination; the APIs enforce their own permissions. `Runner` drops records of other
projects, even when a collection includes subprojects.

## 2. Copy and describe the module

From the plugin directory:

```sh
cp doc/examples/project_notes.rb lib/redmine_mirror/adapters/project_notes.rb
```

Change the `File:` header to the new location, remove the copy instructions,
and adapt the following five methods to your API:

| Method | Meaning |
| --- | --- |
| `key` | Unique stable Mirror module key, persisted in settings and correspondences |
| `collection` | Plural API path and list response key |
| `entity` | Singular GET/POST/PUT wrapper |
| `fields` | Destination fields protected against local modifications |
| `payload` | Values to write, including the destination `project_id` |

The fingerprint must include every field the payload can overwrite, but no generated
IDs or timestamps. If the API returns nested references or normalized values, override
`destination_attributes(record)` to return the managed representation used for conflict
checks, as the built-in `Issues` adapter does.

Never change a module key after imports: correspondences are stored under it, so objects
would be duplicated.

## 3. Load and register it

Add this require after the base adapter is loaded in `lib/redmine_mirror/adapters.rb`:

```ruby
require_relative "adapters/project_notes"
```

Add this registration inside `module RedmineMirror`, after `REGISTRY` is initialized,
in `lib/redmine_mirror.rb`:

```ruby
REGISTRY.register(Adapters::ProjectNotes.new)
```

Add translated labels to the existing locale roots:

```yaml
# config/locales/en.yml, under en:
  label_mirror_module_project_notes: Project notes
```

```yaml
# config/locales/fr.yml, under fr:
  label_mirror_module_project_notes: Notes du projet
```

Restart web and worker processes. A member who configures Mirror selects the module in
**Settings → Mirror → Connection** and saves; Mirror then shows its tab (empty for this example)
and includes it in previews, schedules and logs. Existing projects do not select it
automatically.

Unknown modules show IDs as plain text. For clickable links, extend `mirror_object_link`
in `app/helpers/mirror_helper.rb` with your module's routes, or implement `local_path`
and `remote_path` (see below).

## 4. Add reference mappings only if needed

Reuse `Users` for identity resolution and existing `MappingTable` types whenever
possible. For example, a module referencing issue priorities can add:

```ruby
def mapping_tables
  [MappingTable.new("priority")]
end

def catalog_references(client, _project_id)
  { "priority" => client.get("enumerations/issue_priorities.json").fetch("issue_priorities") }
end

def payload(record, project_id, mappings, _lookup, options: {})
  record.slice("title", "body").merge(
    "project_id" => project_id,
    "priority_id" => map(mappings, "priority", record.fetch("priority").fetch("id"))
  )
end

def fields
  %w[title body priority_id]
end

def destination_attributes(record)
  record.slice("title", "body").merge("priority_id" => record.fetch("priority").fetch("id"))
end
```

This assumes the notes API returns `priority` as `{ "id": ... }`. The controller
renders and validates the priority table by itself. For a new reference type, subclass
`MappingTable` and implement `local_records(project)` with existing, permitted local
objects only; declare it in `mapping_tables`, supply its catalogue (undeclared tables are
rejected) and add `label_mirror_mapping_<table_key>` to both locales.

For user references, add `users` to `dependencies`, provide `referenced_users(record)`
for discovery and call `Users#resolve`; never create accounts. The user table is shared
by the project's modules.

## 5. Resolve dependencies before importing links

Declare dependencies when your payload needs another module's destination IDs:

```ruby
def dependencies
  ["issue_tracking"]
end
```

In the payload, `lookup.call("issue_tracking", source_issue_id)` returns the
destination ID or, during a first preview, `planned:<source_id>`. Check missing
references explicitly, and never convert planned IDs with `Integer` or write them to
native models: they only validate the preview.

Dependencies run first; the registry rejects unknown keys and cycles and runs each
adapter once. It never launches another project's import: cross-project links need that
project synchronized, then a rerun. See `Relations` and `Hierarchy` for deferred links.

To warn in your module tab before a run, count what you need when the references are
read, then compare it with this Redmine when the tab is shown. Integers add up across
records; hashes add up key by key:

```ruby
def catalog_statistics(record)
  file_size_statistics(record.fetch("attachments", [])) # { "sizes_kb" => { "120" => 1 } }
end

def overview_checks(_project, _setting, statistics)
  oversized_checks(statistics) # [{ key: :locale_key, count: 2, args: {}, link: nil }]
end
```

## 6. Verify before enabling real writes

The example's test covers preview, project isolation, creation, repeated imports,
source updates and refused local changes:

```sh
ruby test/adapter_example_test.rb
```

Adapt them to your endpoint, adding pagination, permission and mapping cases. Then run
the full Redmine suite and try two real instances, preview first. The example's in-memory
client does not prove that a real API works.

## Ship an adapter from another Redmine plugin

An adapter can live in the plugin that owns the data, such as `redmine_sla` or
`redmine_reporting`, which then versions its schema, REST API and adapter together.
Mirror exposes this contract:

| Element | Contract (adapter API version 1) |
| --- | --- |
| `RedmineMirror::ADAPTER_API_VERSION` | Contract version provided by the installed Mirror |
| `RedmineMirror.register_adapter(adapter)` | Registers an adapter instance; raises `RedmineMirror::Error` when the contract is not met |
| `api_version` | Inherited from `Adapters::Base`; override it with the literal version your adapter was written for |
| `key` | Lowercase letters, digits and underscores, 64 characters at most. Prefix it with your plugin name, such as `sla_project_trackers` |
| `phase` | `:references` (before issues), `:default` or `:history` (after current issue fields) |
| `available?` | Return false when a prerequisite is missing on this destination; the module is then hidden and cannot run |
| `local_path(id, project)` / `remote_path(id, setting)` | Native destination path and source path relative to the source URL, or nil to show the bare ID. `MappingTable` subclasses provide the same two methods for their references |
| `settings_partial` | Optional partial, from your plugin's views, rendered in the module tab with the local `adapter` |
| `project_module` | Redmine project module the destination project needs (e.g. `:wiki`), or nil; the module tab warns when it is disabled |
| `source_state` / `delete_local` | Mirror mode: whether an object the source no longer lists is `"deleted"`, `"moved"`, `"hidden"` or `"present"` (`remote_state` helps), and how to delete its local copy. Without them, source deletions are not propagated for the module |

Redmine runs each plugin's `init.rb` in alphabetical order, at boot and after each code
reload. A plugin sorting after `redmine_mirror` registers its adapters at the end of
`init.rb`, once per process. Keep the adapter file outside `app/` and `lib/`: Redmine
eager-loads them in production, and a class inheriting from Mirror would break the boot
of a Redmine without Mirror.

```ruby
# redmine_example/init.rb, after Redmine::Plugin.register
if Redmine::Plugin.installed?(:redmine_mirror)
  load File.expand_path("mirror/adapters.rb", __dir__)
  adapter = RedmineExample::ExampleNotesAdapter.new
  RedmineMirror.register_adapter(adapter) unless RedmineMirror::REGISTRY[adapter.key]
end
```

```ruby
# redmine_example/mirror/adapters.rb
module RedmineExample
  class ExampleNotesAdapter < RedmineMirror::Adapters::Base
    def api_version; 1; end
    def key; "example_notes"; end
    def collection; "example_notes"; end
    def entity; "example_note"; end
    def fields; %w[title body]; end
    def payload(record, project_id, _mappings, _lookup, options: {})
      record.slice("title", "body").merge("project_id" => project_id)
    end
    def local_path(id, _project); "/example_notes/#{id}"; end
    def remote_path(id, _setting); "example_notes/#{id}"; end
  end
end
```

An adapter shipped with the data's plugin can instead write natively, like
`Adapters::ProjectReferences`: implement `synchronize` and save the object with its
correspondence in one transaction; the source then only needs a read-only API. See
`mirror/adapters.rb` in redmine_reporting. Word errors "Existing local ..." or "Local
modification ..." so Mirror records a conflict the project can resolve.

In development, restart the server after a change.
Put `label_mirror_module_<key>` and `label_mirror_mapping_<table_key>` in your plugin's
locale files. An adapter declaring another API version is refused: release a compatible
adapter rather than relaxing the check.

If the owning plugin is removed, projects keep their configuration and correspondences.
The connection tab lists the missing module, and runs are refused until the plugin is
back or a member who configures Mirror deselects it: a selected module is never skipped
silently.

Version 1 does not forward arbitrary options from the mapping form: use reference tables,
or extend Mirror with code and tests (see below).

## What Mirror already handles

`Runner` compares fingerprints, writes REST objects, stores source/local IDs and emits
progress and log events. `Synchronization` previews everything before applying, holds the
project lease and handles schedules. Registered adapters get all of this for free.

There is no transaction across HTTP writes and mapping storage, no propagated deletion
and no forced overwrite. Your endpoints must not leak private data in notifications or logs.

## When to use a different base class

| Need | Starting point |
| --- | --- |
| Numeric REST objects with list/read/create/update endpoints | `Adapters::Base` and the five-method example |
| Local categories or versions before issues | `Adapters::ProjectReferences` |
| Historical children with native timestamps | `Adapters::IssueChildren` |
| A second pass updating existing issues | `Adapters::IssueState` |
| Custom routes or title-based identity, such as wiki pages | A local adapter implementing `synchronize`, with a numeric key derived from the title, as `Adapters::Wiki` does |

Local adapters implement `synchronize` with the arguments `Runner` passes, and return
an event with `module`, `source_id`, `destination_id` and `action`. They own their conflict
checks, preview behavior and native transaction, and require the local destination and
`DatabaseStore`. `Relations` and `Hierarchy` use engine-specific options; the mapping
controller only accepts its known option fields, so new options need code and tests.
