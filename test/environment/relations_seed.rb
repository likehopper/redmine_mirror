# frozen_string_literal: true
# File: redmine_mirror/test/environment/relations_seed.rb
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
Setting.cross_project_issue_relations = "1"
main = Project.find_by!(identifier: "mirror-demo")
alice = User.find_by!(login: "alice")
projects = %w[mirror-child-a mirror-child-b mirror-independent].map do |identifier|
  project = Project.find_or_initialize_by(identifier: identifier)
  if project.new_record?
    project.assign_attributes(name: identifier, parent: identifier == "mirror-independent" ? nil : main,
      is_public: false, enabled_module_names: %w[issue_tracking time_tracking])
    project.save!
    project.trackers = Tracker.all
    Member.create!(project: project, user: alice, roles: [Role.find_by!(name: "Manager")])
  end
  2.times do |index|
    project.issues.find_or_create_by!(subject: "#{identifier} issue #{index + 1}") do |issue|
      issue.author = alice
      issue.tracker = Tracker.first
      issue.status = IssueStatus.first
      issue.priority = IssuePriority.default
      issue.is_private = index.zero?
    end
  end
  project
end
first, second = main.issues.order(:id).first(2)
a, b, independent = projects.map { |project| project.issues.order(:id).first }
[[first, second, "precedes", 2], [first, a, "relates", nil], [a, b, "relates", nil], [first, independent, "relates", nil]].each do |from, to, kind, delay|
  IssueRelation.find_or_create_by!(issue_from: from, issue_to: to, relation_type: kind) { |row| row.delay = delay }
end
puts "Relations fixtures ready: main, two children, independent project and four relations"
