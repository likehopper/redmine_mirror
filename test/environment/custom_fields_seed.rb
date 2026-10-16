# frozen_string_literal: true
# File: redmine_mirror/test/environment/custom_fields_seed.rb
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
project = Project.find_or_create_by!(identifier: "mirror-custom-fields-demo") do |row|
  row.name = "Mirror custom fields fixtures"
  row.enabled_module_names = %w[issue_tracking]
end
project.trackers = Tracker.all
Member.find_or_create_by!(project: project, user: alice) { |row| row.roles = [Role.find_by!(name: "Manager")] }
version = project.versions.find_or_create_by!(name: "Source custom version")
specs = { "Text" => ["string", false], "Options" => ["list", true], "Number" => ["int", false],
  "Date" => ["date", false], "Flag" => ["bool", false], "User" => ["user", false], "Version" => ["version", false] }
fields = specs.to_h do |name, (format, multiple)|
  field = IssueCustomField.find_or_initialize_by(name: "Mirror CF #{name}")
  field.assign_attributes(field_format: format, multiple: multiple, visible: true, editable: true,
    is_for_all: false, trackers: Tracker.all, projects: [project])
  field.possible_values = ["Remote A", "Remote B"] if format == "list"
  if name == "Text"
    field.is_required = true
    field.default_value = "Required default"
  end
  field.save!
  [name, field]
end
2.times do |index|
  subject = "Mirror custom fields issue #{index + 1}"
  issue = project.issues.find_or_initialize_by(subject: subject)
  next if issue.persisted? && issue.journals.exists?(notes: "Custom field history fixture")
  issue.assign_attributes(tracker: Tracker.first, status: IssueStatus.first, priority: IssuePriority.default, author: alice, is_private: index == 1)
  issue.custom_field_values = { fields["Text"].id.to_s => "Initial text", fields["Options"].id.to_s => ["Remote A", "Remote B"],
    fields["Number"].id.to_s => "42", fields["Date"].id.to_s => "2026-01-02", fields["Flag"].id.to_s => "1",
    fields["User"].id.to_s => alice.id.to_s, fields["Version"].id.to_s => version.id.to_s }
  issue.save!
  issue = Issue.find(issue.id)
  issue.init_journal(alice, "Custom field history fixture").private_notes = index == 1
  issue.custom_field_values = { fields["Text"].id.to_s => "Updated text", fields["Options"].id.to_s => ["Remote B"] }
  issue.save!
end
puts "Custom field fixtures ready: seven formats, required field, multiple values, reference fields, two issues and dated history"
