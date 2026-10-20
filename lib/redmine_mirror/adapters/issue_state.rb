# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/issue_state.rb
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
# Apply secondary issue state after issue mappings exist, with independent conflict checks.

module RedmineMirror
  module Adapters
    # A separate pass runs only after all demands in this project have mappings.
    class IssueState < IssueChildren
      # Records are the issues themselves.
      def source_issue_ids(record); [record.fetch("id")]; end

      def records(client, project_id)
        Issues.new.records(client, project_id).lazy.map do |issue|
          issue_detail(client, issue.fetch("id"), "watchers")
        end
      end

      # Secondary state has its own fingerprint, independent of the issue REST pass.
      # First imports must also respect adapter-specific existing local state.
      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        local_id = lookup.call("issue_tracking", record.fetch("id"))
        event = { module: key, source_id: record.fetch("id"), destination_id: local_id, action: "update" }
        issue = Issue.find_by(id: local_id, project_id: project_id) unless local_id.to_s.start_with?("planned:")
        raise Error, "Missing destination issue correspondence" if apply && !issue
        desired = desired_state(record, mappings, lookup, store, issue)
        return event.merge(action: "ignored", reason: "Remote parent not synchronized", remote_issue_id: record.fetch("parent").fetch("id")) if desired == :pending
        return event unless issue
        previous = store.find(key, record.fetch("id"))
        current = local_state(issue)
        if previous && digest(current) != previous.fetch("destination_fingerprint")
          Policy.local_change!("Local modification detected for #{key} source ID #{record.fetch('id')}")
          TextFormat.note("local_overwritten")
        elsif !previous && !accept_existing_state? && current != empty_state && current != desired
          Policy.local_change!("Existing local #{key} requires manual resolution")
          TextFormat.note("local_overwritten")
        end
        validate_state(issue, desired) unless current == desired || desired.to_s.start_with?("planned:")
        event[:action] = current == desired ? "unchanged" : "update"
        if apply
          MirrorMapping.transaction do
            write_state(issue, desired) unless current == desired
            store.save(key, record.fetch("id"), "destination_id" => issue.id,
              "source_fingerprint" => digest(desired), "destination_fingerprint" => digest(local_state(issue.reload)))
          end
        end
        event
      end

      def accept_existing_state?; false; end
      def validate_state(_issue, _desired); end
    end
  end
end
