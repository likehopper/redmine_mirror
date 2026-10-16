# frozen_string_literal: true
# File: redmine_mirror/test/environment/seed.rb
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

abort "Disposable test environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable"
Setting.rest_api_enabled = "1"
Setting.login_required = "1"
admin = User.find_by!(login: "admin")
admin.password = admin.password_confirmation = "Mirror-test-2026!"
admin.must_change_passwd = false
admin.save!
role = ENV.fetch("MIRROR_ROLE")
user = User.create!(login: "alice", firstname: "Alice", lastname: "Mirror", mail: "alice@example.invalid",
  password: "Mirror-test-2026!", password_confirmation: "Mirror-test-2026!")
project = Project.create!(name: role == "source" ? "Mirror source demo" : "Mirror destination demo", identifier: "mirror-demo",
  is_public: false, enabled_module_names: %w[issue_tracking time_tracking] + (role == "destination" ? ["mirror"] : []))
project.trackers = Tracker.all
manager = Role.find_by!(name: "Manager")
if role == "destination"
  manager.add_permission!(:view_mirror)
  manager.add_permission!(:manage_mirror)
end
Member.create!(project: project, user: user, roles: [manager])
if role == "source"
  12.times do |i|
    issue = Issue.create!(project: project, tracker: Tracker.first, author: user, assigned_to: user,
      subject: "Mirror demo issue #{i + 1}", description: "Disposable source data for manual synchronization tests.",
      priority: IssuePriority.default, status: IssueStatus.first, done_ratio: (i % 5) * 20)
    TimeEntry.create!(project: project, issue: issue, user: user, activity: TimeEntryActivity.first,
      spent_on: Date.today - i, hours: 1.5, comments: "Mirror demo work #{i + 1}")
  end
  TimeEntry.create!(project: project, user: user, activity: TimeEntryActivity.first,
    spent_on: Date.today, hours: 0.5, comments: "Project time without an issue")
else
  mappings = {}
  { "tracker" => Tracker, "status" => IssueStatus, "priority" => IssuePriority, "activity" => TimeEntryActivity, "user" => User }.each do |kind, model|
    mappings[kind] = model.all.to_h { |record| [record.id.to_s, record.id] }
  end
  File.write("/mirror-data/mirror.json", JSON.pretty_generate({ source_url: "http://source:3000", destination_url: "http://destination:3000",
    source_project_id: project.id, destination_project_id: project.id, allow_http: true,
    modules: %w[issue_categories project_versions issue_tracking time_tracking], mappings: mappings }))
end
load "/mirror-environment/enrich_source.rb" if role == "source"
puts "Seeded #{role}: #{project.identifier}"
