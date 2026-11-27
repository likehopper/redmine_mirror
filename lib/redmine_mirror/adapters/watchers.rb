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
# Restore mapped issue subscriptions while preserving local subscriptions.

module RedmineMirror
  module Adapters
    class Watchers < IssueState
      def key; "issue_watchers"; end
      def referenced_users(record); record.fetch("watchers", []); end
      def catalog_statistics(record)
        watchers = record.fetch("watchers", [])
        { "watchers" => watchers.size, "watcher_users" => watchers.to_h { |watcher| [watcher.fetch("id").to_s, 1] } }
      end

      # Anonymous mappings have no destination account to subscribe.
      def overview_checks(project, _setting, statistics)
        users = statistics.fetch("watcher_users", {})
        rows = project.mirror_reference_mappings.where(reference_type: "user", source_id: users.keys.map(&:to_i)).index_by { |row| row.source_id.to_s }
        anonymized = users.sum { |id, count| rows[id]&.mode == "anonymous" ? count : 0 }
        checks = []
        checks << { key: :text_mirror_check_watchers_anonymized, count: anonymized } if anonymized.positive?
        checks
      end
      def empty_state; []; end
      def accept_existing_state?; true; end
      def local_state(issue); issue.watcher_users.pluck(:id).sort; end
      # Missing watcher data can mean insufficient source permissions. Distinguish
      # that from an explicitly empty list before touching destination subscriptions.
      def mapped_watchers(record, mappings, _issue)
        raise Error, "Source API did not expose watchers; check source permissions" unless record.key?("watchers")
        record.fetch("watchers").filter_map do |reference|
          id = Users.new.resolve(mappings, reference.fetch("id"))
          next unless id # Anonymized identities cannot receive notifications.
          user = User.find_by(id: id)
          raise Error, "Watcher mapping must reference a destination user" unless user && !user.anonymous?
          id
        end.uniq.sort
      end

      def desired_state(record, mappings, _lookup, _store, issue)
        # Preserve existing subscriptions; remote deletions are not propagated.
        (mapped_watchers(record, mappings, issue) + (issue ? local_state(issue) : [])).uniq.sort
      end

      def write_state(issue, desired)
        current = local_state(issue)
        removed = current - desired
        issue.watchers.where(user_id: removed).destroy_all if removed.any?
        User.where(id: desired - current).each do |user|
          watcher = Watcher.new(watchable: issue, user: user)
          # A source subscription is historical data. Redmine's validation rejects
          # locked and registered users even when their subscription still exists.
          user.active? ? watcher.save! : watcher.save!(validate: false)
        end
        issue.watchers.reset
        issue.watcher_users.reset
      end

      # Additive mode keeps subscriptions created locally by Redmine or users.
      # Source subscriptions are restored whenever this issue is processed,
      # including after Redmine prunes watchers who lost issue visibility.
      def synchronize(record, project_id:, mappings:, lookup:, store:, source:, apply:)
        local_id = lookup.call("issue_tracking", record.fetch("id"))
        event = { module: key, source_id: record.fetch("id"), destination_id: local_id, action: "update" }
        issue = Issue.find_by(id: local_id, project_id: project_id) unless local_id.to_s.start_with?("planned:")
        raise Error, "Missing destination issue correspondence" if apply && !issue
        mapped = mapped_watchers(record, mappings, issue)
        return event unless issue
        current = local_state(issue)
        # Mirror mode: exactly the source watchers, local subscriptions included.
        if Policy.source_wins?
          event[:action] = current == mapped ? "unchanged" : "update"
          if apply
            MirrorMapping.transaction do
              write_state(issue, mapped) unless current == mapped
              store.save(key, record.fetch("id"), "destination_id" => issue.id,
                "source_fingerprint" => digest(mapped), "destination_fingerprint" => digest(mapped & local_state(issue.reload)))
            end
          end
          return event
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
