# frozen_string_literal: true
# File: redmine_mirror/test/environment/references_seed.rb
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
# Build disposable demo records for manual and API synchronization checks.

abort "Disposable source only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "source"
alice = User.find_by!(login: "alice")
%w[mirror-demo mirror-child-a mirror-child-b mirror-independent].each do |identifier|
  project = Project.find_by!(identifier: identifier)
  category = project.issue_categories.find_or_create_by!(name: "Mirror category") { |row| row.assigned_to = alice }
  version = project.versions.find_or_create_by!(name: "Mirror v1") do |row|
    row.description = "Mirror version fixture"
    row.status = "open"
    row.effective_date = Date.new(2026, 12, 1)
    row.sharing = "none"
  end
  issue = project.issues.order(:id).first!
  issue.update_columns(category_id: category.id, fixed_version_id: version.id)
  if identifier == "mirror-child-a" && !issue.journals.exists?(notes: "Mirror fixture: category and version")
    journal = issue.journals.new(user: alice, notes: "Mirror fixture: category and version", created_on: Time.utc(2026, 1, 15, 10))
    journal.notify = false
    %w[category_id fixed_version_id].zip([category.id, version.id]).each do |field, value|
      journal.details.build(property: "attr", prop_key: field, old_value: nil, value: value.to_s)
    end
    journal.save!
  end
end
# A permanent unsynchronized subproject and independent project.
main = Project.find_by!(identifier: "mirror-demo")
%w[mirror-unmapped-child mirror-unmapped-project].each do |identifier|
  project = Project.find_or_create_by!(identifier: identifier) do |row|
    row.name = identifier
    row.parent = main if identifier.end_with?("child")
    row.is_public = false
    row.enabled_module_names = %w[issue_tracking]
  end
  project.trackers = Tracker.all if project.trackers.empty?
  issue = project.issues.find_or_create_by!(subject: "#{identifier} remote only") do |row|
    row.author = alice
    row.tracker = Tracker.first
    row.status = IssueStatus.first
    row.priority = IssuePriority.default
    row.is_private = true
  end
  IssueRelation.find_or_create_by!(issue_from: main.issues.order(:id).first!, issue_to: issue, relation_type: "relates")
end
puts "Reference fixtures and two permanently unmapped targets ready"
