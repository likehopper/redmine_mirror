# frozen_string_literal: true
# File: redmine_mirror/test/environment/reporting_seed.rb
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
# Build the source Reporting configuration; MIRROR_REPORTING_VARIANT=updated changes it.

abort "Disposable test environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable"
abort "Source instance only" unless ENV["MIRROR_ROLE"] == "source"
updated = ENV.fetch("MIRROR_REPORTING_VARIANT", "baseline") == "updated"
bug, feature, support = %w[Bug Feature Support].map { |name| Tracker.find_by!(name: name) }
project = Project.find_by(identifier: "mirror-reporting-demo") ||
  Project.create!(name: "Mirror Reporting demo", identifier: "mirror-reporting-demo", is_public: false,
    enabled_module_names: %w[issue_tracking time_tracking reporting])
project.trackers = [bug, feature, support]
# The subproject inherits its parent's settings: Mirror must not copy them.
child = Project.find_by(identifier: "mirror-reporting-child") ||
  Project.create!(name: "Mirror Reporting child", identifier: "mirror-reporting-child", is_public: false,
    parent: project, enabled_module_names: %w[issue_tracking time_tracking reporting])
ReportingProjectSetting.where(project_id: child.id).delete_all
setting = ReportingProjectSetting.find_or_initialize_by(project_id: project.id)
setting.update!(hours_per_day: updated ? 6 : 7, section_ids: %w[run workload],
  run_tracker_ids: [support.id], build_tracker_ids: [feature.id])

def credit_policy(project, tracker, refills:, **attributes)
  policy = project.reporting_credit_policies.find_or_initialize_by(tracker_id: tracker.id)
  policy.reporting_credit_refills.destroy_all if policy.persisted?
  policy.assign_attributes(attributes)
  refills.each { |refill| policy.reporting_credit_refills.build(refill) }
  policy.save!
end

credit_policy(project, support, name: updated ? "Support contract 2027" : "Support contract", initial_credit_days: 20,
  anniversary_month: 1, anniversary_day: 1, active_from: Date.new(2026, 1, 1), active_until: nil, enabled: true,
  refills: [{month: 7, day: 1, credit_days: updated ? 4 : 3},
            {month: 10, day: 1, credit_days: 2, starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31)}])
credit_policy(project, feature, name: "Feature budget", initial_credit_days: 12.5, anniversary_month: 4, anniversary_day: 1,
  active_from: Date.new(2026, 4, 1), active_until: Date.new(2027, 3, 31), enabled: true, refills: [])
puts "Seeded Reporting source (#{updated ? 'updated' : 'baseline'}): #{project.identifier} ##{project.id}"
