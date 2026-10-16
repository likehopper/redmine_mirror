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
      def desired_state(record, mappings, _lookup, _store, issue)
        raise Error, "Source API did not expose watchers; check source permissions" unless record.key?("watchers")
        mapped = record.fetch("watchers").filter_map do |reference|
          id = Users.new.resolve(mappings, reference.fetch("id"))
          next unless id # Anonymized identities cannot receive notifications.
          user = User.active.find_by(id: id)
          raise Error, "Watcher mapping must reference an active user" unless user
          raise Error, "Mapped watcher cannot view destination issue" if issue && !issue.visible?(user)
          id
        end.uniq.sort
        # Preserve existing subscriptions; remote deletions are not propagated.
        (mapped + (issue ? local_state(issue) : [])).uniq.sort
      end
      def write_state(issue, desired)
        issue.watcher_users = User.where(id: desired).to_a
      end
    end
  end
end
