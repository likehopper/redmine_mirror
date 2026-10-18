# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/mapping_table.rb
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
# Describe mapping choices using existing Redmine objects and project-visible references.

module RedmineMirror
  class MappingTable
    attr_reader :key, :reference_fields

    def initialize(key, reference_fields: [key])
      @key, @reference_fields = key, reference_fields
    end

    def metadata_fields; []; end

    def label
      "label_mirror_mapping_#{key}".to_sym
    end

    def ignore_allowed?; false; end

    def anonymous_allowed?
      key == "user"
    end

    def local_records(project)
      case key
      when "tracker" then project.trackers.sorted
      # Statuses reachable through the project's tracker workflows, when there are any.
      when "status" then project.rolled_up_statuses.presence || IssueStatus.sorted
      when "priority" then IssuePriority.active.sorted
      when "activity" then project.activities
      # Locked members keep the history of people who left (authors, past assignees).
      when "user" then User.where(id: project.memberships.select(:user_id), status: [User::STATUS_ACTIVE, User::STATUS_LOCKED]).sorted
      else raise Error, "Unknown mapping table #{key}"
      end
    end

    def local_path(_id, _project); nil; end
    def remote_path(_id, _setting); nil; end

    def references(record)
      reference_fields.filter_map { |field| record[field] }
    end
  end
end
