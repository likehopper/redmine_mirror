# frozen_string_literal: true
# File: redmine_mirror/test/environment/severity_seed.rb
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

# A "Severity" list on the demo issues, for cross-field correspondences: the severity
# feeds the destination priority, the source priority goes to a destination field.
abort "Disposable source only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "source"
project = Project.find_by!(identifier: "mirror-demo")
alice = User.find_by!(login: "alice")
severity = IssueCustomField.find_or_initialize_by(name: "Severity")
severity.assign_attributes(field_format: "list", possible_values: %w[minor major blocker], multiple: false, visible: true,
  editable: true, is_for_all: false, is_filter: true, trackers: Tracker.all, projects: [project])
severity.save!
issues = project.issues.order(:id).to_a
issues.each_with_index do |issue, index|
  # The fourth issue of each group has no severity: it takes the priority without a value.
  value = %w[minor major blocker].fetch(index % 4, nil)
  issue.custom_field_values = { severity.id.to_s => value.to_s }
  issue.save_custom_field_values
end
# A raised severity and priority in the first issue's history.
issue = issues.first
unless issue.journals.exists?(notes: "Mirror fixture: severity raised")
  high = IssuePriority.find_by!(name: "High")
  Journal.transaction do
    journal = Journal.create!(journalized: issue, user: alice, notes: "Mirror fixture: severity raised", created_on: Time.utc(2026, 1, 1, 15))
    journal.details.create!(property: "cf", prop_key: severity.id.to_s, old_value: "minor", value: "blocker")
    journal.details.create!(property: "attr", prop_key: "priority_id", old_value: issue.priority_id.to_s, value: high.id.to_s)
    CustomValue.where(customized: issue, custom_field: severity).update_all(value: "blocker")
    issue.update_columns(priority_id: high.id)
  end
end
puts "Severity fixtures ready: #{issues.size} issues, one raised in their history"
