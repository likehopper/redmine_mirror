# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters/time_entries.rb
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
# Import issue-linked time with mapped activities and an explicit author account.

module RedmineMirror
  module Adapters
    class TimeEntries < Base
      def initialize(users: Users.new)
        @user_adapter = users
      end

      def referenced_users(record)
        [record["user"]].compact
      end

      def catalog_references(client, _project_id)
        { "activity" => client.get("enumerations/time_entry_activities.json").fetch("time_entry_activities") }
      end

      def mapping_tables
        [MappingTable.new("activity")]
      end

      def key; "time_tracking"; end
      def collection; "time_entries"; end
      def entity; "time_entry"; end
      def dependencies; ["users", "issue_tracking"]; end
      def fields; %w[hours comments spent_on activity_id user_id issue_id]; end

      def payload(record, project_id, mappings, lookup, options: {})
        result = record.slice("hours", "comments", "spent_on")
        result["activity_id"] = map(mappings, "activity", record.fetch("activity").fetch("id"))
        result["user_id"] = @user_adapter.resolve(mappings, record.fetch("user").fetch("id"), required: true, options: options)
        if record["issue"]
          result["issue_id"] = lookup.call("issue_tracking", record["issue"].fetch("id"))
          raise Error, "Issue has no synchronized destination" unless result["issue_id"]
        else
          result["issue_id"] = nil
        end
        result.merge("project_id" => project_id)
      end

      def destination_attributes(record)
        result = super
        %w[activity user issue].each { |kind| result["#{kind}_id"] = record[kind] && record[kind]["id"] }
        result
      end
    end
  end
end
