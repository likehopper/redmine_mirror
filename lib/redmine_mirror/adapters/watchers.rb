# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/watchers.rb
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
# Add mapped observers with native visibility checks while preserving local subscriptions.

module RedmineMirror
  module Adapters
    class Watchers < IssueState
      def key; "issue_watchers"; end
      def referenced_users(record); record.fetch("watchers", []); end
      def empty_state; []; end
      def accept_existing_state?; true; end
      def local_state(issue); issue.watcher_users.pluck(:id).sort; end
      # Missing watcher data can mean insufficient source permissions. Distinguish
      # that from an explicitly empty list before touching destination subscriptions.
      def mapped_watchers(record, mappings, issue)
        raise Error, "Source API did not expose watchers; check source permissions" unless record.key?("watchers")
        record.fetch("watchers").filter_map do |reference|
          id = Users.new.resolve(mappings, reference.fetch("id"))
          next unless id # Anonymized identities cannot receive notifications.
          user = User.find_by(id: id)
          # Redmine refuses locked watchers, who receive no notification anyway.
          next if user&.locked?
          raise Error, "Watcher mapping must reference an active user" unless user&.active?
          raise Error, "Mapped watcher cannot view destination issue" if issue && !issue.visible?(user)
          id
        end.uniq.sort
      end

      def desired_state(record, mappings, _lookup, _store, issue)
        # Preserve existing subscriptions; remote deletions are not propagated.
        (mapped_watchers(record, mappings, issue) + (issue ? local_state(issue) : [])).uniq.sort
      end

      def write_state(issue, desired)
        issue.watcher_users = User.where(id: desired).to_a
      end

      # Additive module: only the watchers Mirror adds are its own. Redmine subscribes
      # authors and the API account that writes issues, and users subscribe themselves;
      # those local watchers are kept and are not conflicts. A conflict is a mirrored
      # watcher removed locally while the source still lists it.
      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        local_id = lookup.call("issue_tracking", record.fetch("id"))
        event = { module: key, source_id: record.fetch("id"), destination_id: local_id, action: "update" }
        issue = Issue.find_by(id: local_id, project_id: project_id) unless local_id.to_s.start_with?("planned:")
        raise Error, "Missing destination issue correspondence" if apply && !issue
        mapped = mapped_watchers(record, mappings, issue)
        return event unless issue
        current = local_state(issue)
        previous = store.find(key, record.fetch("id"))
        if previous && previous.fetch("source_fingerprint") == digest(mapped) && digest(mapped & current) != previous.fetch("destination_fingerprint")
          raise Error, "Local modification detected for #{key}: a watcher added from the source was removed locally"
        end
        missing = mapped - current
        event[:action] = missing.empty? ? "unchanged" : "update"
        if apply
          MirrorMapping.transaction do
            write_state(issue, (current + missing).uniq.sort) unless missing.empty?
            store.save(key, record.fetch("id"), "destination_id" => issue.id,
              "source_fingerprint" => digest(mapped), "destination_fingerprint" => digest(mapped & local_state(issue.reload)))
          end
        end
        event
      end
    end
  end
end
