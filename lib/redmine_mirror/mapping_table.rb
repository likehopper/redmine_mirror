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
    def ignore_label; :label_mirror_ignore_field; end

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
      when "user" then local_users(project)
      else raise Error, "Unknown mapping table #{key}"
      end
    end

    # Locked accounts keep the history of people who left (authors, past assignees).
    # With the Members module, members managers choose among all accounts, as Redmine
    # offers them when adding a member; others see the members and the users mapped.
    def local_users(project)
      # Labels show the login, email and company (MirrorHelper#mirror_user_label).
      users = User.where(status: [User::STATUS_ACTIVE, User::STATUS_LOCKED]).preload(:email_address, :preference, :custom_values)
      return users.sorted if RedmineMirror.members_manager?(project)
      mapped = project.mirror_reference_mappings.where(reference_type: "user", mode: "existing").select(:destination_id)
      users.where(id: project.memberships.select(:user_id)).or(users.where(id: mapped)).sorted
    end

    def local_path(_id, _project); nil; end
    def remote_path(_id, _setting); nil; end

    def references(record)
      reference_fields.filter_map { |field| record[field] }
    end
  end
end
