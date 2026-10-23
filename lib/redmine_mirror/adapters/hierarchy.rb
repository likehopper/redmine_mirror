# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/hierarchy.rb
#
# Redmine Mirror - modular project import and asynchronous replication.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, either version 2 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE for details.
#
# Resolve parents across configured projects using native nested-set validation.

module RedmineMirror
  module Adapters
    class Hierarchy < IssueState
      def key; "issue_hierarchy"; end
      def records(client, project_id); Issues.new.records(client, project_id); end
      # A parent left out of the import leaves the link out too, rather than pending.
      def source_issue_ids(record); [record.fetch("id"), record.dig("parent", "id")].compact; end
      def catalog_statistics(record); { "with_parent" => record["parent"] ? 1 : 0 }; end
      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:, track_blocks: false)
        event = super(record, project_id: project_id, mappings: mappings, lookup: lookup, store: store, source: source, apply: apply)
        if apply && store.respond_to?(:pending_parent)
          if event[:reason] == "Remote parent not synchronized"
            store.pending_parent(record, local_issue_id: event[:destination_id], status: "pending", reason: event[:reason])
          else
            store.resolve_pending_parent(record.fetch("id"))
          end
        end
        event
      rescue Error => error
        if (apply || track_blocks) && store.respond_to?(:pending_parent)
          store.pending_parent(record, local_issue_id: lookup.call("issue_tracking", record.fetch("id")), status: "blocked", reason: error.message)
        end
        raise
      end
      def empty_state; nil; end
      def local_state(issue); issue.parent_id; end
      # A missing remote parent is deferred rather than converted into an unrelated
      # local ID; another configured project may provide it on a later run.
      def desired_state(record, _mappings, lookup, store, _issue)
        return nil unless record["parent"]
        source_id = record.fetch("parent").fetch("id")
        lookup.call("issue_tracking", source_id) || store.resolve_issue(source_id) || :pending
      end
      def validate_state(issue, desired)
        issue.parent_issue_id = desired
        raise Error, "Destination rejected parent: #{issue.errors.full_messages.join(', ')}" unless issue.valid?
      end
      def write_state(issue, desired)
        # Use native nested-set validation, including cycles and cross-project rules.
        dates = issue.attributes.slice("created_on", "updated_on", "closed_on")
        issue.parent_issue_id = desired
        issue.save!
        issue.reload.update_columns(dates)
      end
    end
  end
end
