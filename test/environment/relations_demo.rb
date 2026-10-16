# frozen_string_literal: true
# File: redmine_mirror/test/environment/relations_demo.rb
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

abort "Disposable destination only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "destination"
original = Project.find_by!(identifier: "mirror-demo").mirror_project_setting
settings = [original]
%w[mirror-child-a mirror-child-b mirror-independent].each do |identifier|
  project = Project.find_or_initialize_by(identifier: identifier)
  if project.new_record?
    project.assign_attributes(name: identifier, parent: identifier == "mirror-independent" ? nil : original.project,
      enabled_module_names: %w[mirror issue_tracking time_tracking], is_public: false)
    project.save!
    project.trackers = Tracker.all
    Member.create!(project: project, user: User.find_by!(login: "alice"), roles: [Role.find_by!(name: "Manager")])
  end
  setting = project.mirror_project_setting
  unless setting
    source = original.source_client.get("projects/#{identifier}.json").fetch("project")
    setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: source.fetch("id"))
    setting.api_key = original.api_key
    setting.selected_modules = %w[issue_categories project_versions issue_relations]
    setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: setting.source_project_id, adapters: setting.adapters).fetch
    setting.save!
    original.project.mirror_reference_mappings.each do |row|
      next unless setting.source_catalog.fetch(row.reference_type, {}).key?(row.source_id.to_s)
      project.mirror_reference_mappings.create!(reference_type: row.reference_type, source_id: row.source_id, destination_id: row.destination_id, mode: row.mode)
    end
  end
  setting.selected_modules = setting.selected_modules + %w[issue_categories project_versions]
  setting.save!
  settings << setting
end
original.selected_modules = original.selected_modules + %w[issue_categories project_versions issue_relations]
original.save!
Setting.cross_project_issue_relations = "1"
# First import all endpoints, then revisit relations that were unavailable earlier.
2.times do
  settings.each do |setting|
    run = RedmineMirror::Synchronization.enqueue(setting, apply: true, trigger: "operator", user: User.find_by!(login: "admin"))
    RedmineMirror::Synchronization.execute(run)
    run.reload
    abort "Demo import failed: #{run.error_message}" unless run.status == "succeeded"
    puts "#{setting.project.identifier}: run #{run.id}, #{run.module_counts.inspect}"
  end
end
puts "Cross-project relations demo ready"
