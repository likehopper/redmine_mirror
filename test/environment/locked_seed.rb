# frozen_string_literal: true
# File: redmine_mirror/test/environment/locked_seed.rb
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
User.current = User.find_by!(login: "admin")
alice = User.find_by!(login: "alice")
leaver = User.find_by(login: "mirror-leaver") || User.create!(login: "mirror-leaver", firstname: "Lea", lastname: "Leaver",
  mail: "mirror-leaver@example.invalid", password: "Mirror-test-2026!", password_confirmation: "Mirror-test-2026!")
project = Project.find_or_create_by!(identifier: "mirror-locked-demo") do |row|
  row.name = "Mirror locked references fixtures"
  row.enabled_module_names = %w[issue_tracking time_tracking]
end
project.trackers = Tracker.all
manager = Role.find_by!(name: "Manager")
[alice, leaver].each { |user| Member.find_or_create_by!(project: project, user: user) { |row| row.roles = [manager] } }
version = project.versions.find_or_create_by!(name: "Mirror shipped release")
subject = "Mirror issue of a user who left"
unless project.issues.exists?(subject: subject)
  # Issues are assigned while the version is open; it is closed afterwards.
  version.update!(status: "open")
  issue = Issue.create!(project: project, tracker: Tracker.first, author: leaver, assigned_to: leaver, fixed_version: version,
    subject: subject, priority: IssuePriority.default, status: IssueStatus.first)
  issue = Issue.find(issue.id)
  issue.init_journal(leaver, "Note by a user who left")
  issue.save!
  issue.add_watcher(leaver)
  issue.add_watcher(alice)
  TimeEntry.create!(project: project, issue: issue, user: leaver, activity: TimeEntryActivity.first,
    spent_on: Date.today, hours: 2, comments: "Time of a user who left")
end
version.update!(status: "closed")
puts "Locked reference fixtures ready: issue authored by and assigned to mirror-leaver, closed version, note, watcher, time entry"
