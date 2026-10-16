# frozen_string_literal: true
# File: redmine_mirror/test/environment/issue_state_seed.rb
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
Setting.cross_project_subtasks = "system"
alice = User.find_by!(login: "alice")
outsider = User.find_or_create_by!(login: "mirror-observer") do |user|
  user.firstname = "External"
  user.lastname = "Observer"
  user.mail = "mirror-observer@example.invalid"
  user.password = user.password_confirmation = "Mirror-test-2026!"
end
root = Project.find_or_create_by!(identifier: "mirror-state-demo") do |project|
  project.name = "Mirror hierarchy and watchers fixtures"
  project.is_public = true
  project.enabled_module_names = %w[issue_tracking]
end
root.trackers = Tracker.all
Member.find_or_create_by!(project: root, user: alice) { |member| member.roles = [Role.find_by!(name: "Manager")] }
projects = [root] + %w[mirror-state-child-a mirror-state-child-b mirror-state-independent mirror-state-unmapped].map do |identifier|
  project = Project.find_or_create_by!(identifier: identifier) do |row|
    row.name = identifier
    row.is_public = true
    row.parent = root if identifier.include?("child")
    row.enabled_module_names = %w[issue_tracking]
  end
  project.trackers = Tracker.all
  project
end
projects.each do |project|
  2.times do |index|
    project.issues.find_or_create_by!(subject: "#{project.identifier} issue #{index + 1}") do |issue|
      issue.author = alice
      issue.tracker = Tracker.first
      issue.status = IssueStatus.first
      issue.priority = IssuePriority.default
    end
  end
end
# Internal and cross-project parents, including a permanently unmirrored target.
parents = [projects[0].issues.order(:id).first, projects[0].issues.order(:id).first,
  projects[3].issues.order(:id).first, projects[4].issues.order(:id).first]
children = [projects[0].issues.order(:id).second, projects[1].issues.order(:id).second,
  projects[2].issues.order(:id).second, projects[1].issues.order(:id).first]
children.zip(parents).each do |child, parent|
  child.parent_issue_id = parent.id
  child.save!
end
root.issues.order(:id).first.watcher_users = [alice, outsider]
puts "Hierarchy fixtures: internal, two subprojects, independent and unmirrored parents; non-member observer #{outsider.id}"
