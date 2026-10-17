# frozen_string_literal: true
# File: redmine_mirror/test/environment/relations_smoke.rb
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
# Exercise Mirror behavior against the disposable Redmine environment.

abort "Disposable destination only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "destination"
original = Project.find_by!(identifier: "mirror-demo").mirror_project_setting
previous_cross = Setting.cross_project_issue_relations
projects = []
settings = []
def execute_relations(setting, apply: true, expected: "succeeded")
  run = RedmineMirror::Synchronization.enqueue(setting, apply: apply, trigger: "operator", user: User.find_by!(login: "admin"))
  RedmineMirror::Synchronization.execute(run)
  run.reload
  # An object error leaves the others written by default: "partial" counts as a failure here.
  actual = run.status == "partial" ? "failed" : run.status
  raise "Unexpected run: #{run.status}: #{run.error_message}" unless actual == expected
  run
end
begin
  %w[mirror-demo mirror-child-a mirror-child-b mirror-independent].each_with_index do |identifier, index|
    source_project = original.source_client.get("projects/#{identifier}.json").fetch("project")
    project = Project.create!(name: "Relations #{identifier}", identifier: "relations-#{SecureRandom.hex(4)}", parent: index.between?(1, 2) ? projects.first : nil,
      enabled_module_names: %w[mirror issue_tracking])
    projects << project
    project.trackers = Tracker.all
    Member.create!(project: project, user: User.find_by!(login: "alice"), roles: [Role.find_by!(name: "Manager")])
    setting = MirrorProjectSetting.new(project: project, source_url: "http://gateway:3101", source_project_id: source_project.fetch("id"))
    setting.api_key = original.api_key
    setting.selected_modules = %w[issue_categories project_versions issue_tracking]
    setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: setting.source_project_id, adapters: setting.adapters).fetch
    setting.save!
    settings << setting
    original.project.mirror_reference_mappings.each do |row|
      next unless setting.source_catalog.fetch(row.reference_type, {}).key?(row.source_id.to_s)
      project.mirror_reference_mappings.create!(reference_type: row.reference_type, source_id: row.source_id, destination_id: row.destination_id, mode: row.mode)
    end
  end
  main = settings.first
  main.selected_modules = %w[issue_categories project_versions issue_relations]
  main.save!
  preview = execute_relations(main, apply: false)
  raise "Preview wrote data" if projects.first.issues.exists?
  raise "Missing ignored events" unless preview.log_events.count { |event| event["action"] == "ignored" } == 4
  raise "Preview persisted pending rows" if MirrorPendingRelation.where(project_id: projects.first.id).exists?
  execute_relations(main)
  raise "Internal relation lost" unless IssueRelation.where(issue_from_id: projects.first.issues.select(:id)).count == 1
  main.update!(module_options: { "issue_relations" => { "missing_target" => "note" } })
  execute_relations(main)
  execute_relations(main)
  notes = Journal.where(journalized: projects.first.issues).where("notes LIKE ?", "Mirror: remote relation%")
  raise "Notes duplicated" unless notes.count == 4 && notes.all?(&:private_notes)
  settings.drop(1).each { |setting| execute_relations(setting) }
  Setting.cross_project_issue_relations = "0"
  rejected = execute_relations(main, expected: "failed")
  raise "Missing cross-project rejection" unless rejected.error_message.include?("Destination rejected relation")
  raise "Blocked relation not recorded" unless MirrorPendingRelation.where(project_id: projects.first.id, status: "blocked").exists?
  Setting.cross_project_issue_relations = "1"
  execute_relations(main)
  settings.drop(1).each do |setting|
    setting.selected_modules = %w[issue_categories project_versions issue_relations]
    setting.save!
    execute_relations(setting)
  end
  runs = settings.map { |setting| execute_relations(setting) }
  raise "Relations not idempotent" unless runs.all? { |run| run.log_events.all? { |event| %w[unchanged ignored].include?(event["action"]) } }
  relations = IssueRelation.where(issue_from_id: Issue.where(project_id: projects.map(&:id)).select(:id))
  raise "Duplicate or missing cross relations" unless relations.count == 4
  raise "Delay lost" unless relations.find_by!(relation_type: "precedes").delay == 2
  raise "Missing cross relation" unless relations.count { |row| row.issue_from.project_id != row.issue_to.project_id } == 3
  raise "Notes duplicated after resolution" unless notes.count == 4
  raise "Permanent pending relations missing" unless MirrorPendingRelation.where(project_id: projects.first.id, status: "pending").count == 2
  raise "Resolved relations still blocked" if MirrorPendingRelation.where(project_id: projects.first.id, status: "blocked").exists?
  # A read-only source key cannot list categories, so their default assignee is unknown.
  categories_listed = begin
    original.source_client.get("projects/#{original.source_project_id}/issue_categories.json")
    true
  rescue RedmineMirror::Error
    false
  end
  projects.each do |project|
    category = project.issue_categories.find_by!(name: "Mirror category")
    version = project.versions.find_by!(name: "Mirror v1")
    raise "Category assignee lost" unless category.assigned_to_id == (categories_listed ? User.find_by!(login: "alice").id : nil)
    raise "Version due date lost" unless version.effective_date == Date.new(2026, 12, 1)
    raise "Version metadata lost" unless version.status == "open" && version.sharing == "none"
    issue = project.issues.where.not(category_id: nil).first!
    raise "Issue reference lost" unless issue.category_id == category.id && issue.fixed_version_id == version.id
  end
  child = settings[1]
  child.selected_modules = child.selected_modules + ["issue_journals"]
  child.save!
  execute_relations(child)
  journal = Journal.where(journalized: projects[1].issues).find_by!(notes: "Mirror fixture: category and version")
  expected = { "category_id" => projects[1].issue_categories.first.id, "fixed_version_id" => projects[1].versions.first.id }
  journal.details.each { |detail| raise "Historical reference lost" unless detail.value.to_i == expected.fetch(detail.prop_key) }
  category = projects.first.issue_categories.first
  original_name = category.name
  category.update_columns(name: "Local category edit")
  category_conflict = execute_relations(main, expected: "failed")
  raise "Category conflict lost" unless category_conflict.error_message.include?("Local modification")
  category.update_columns(name: original_name)
  changed = relations.find_by!(relation_type: "precedes")
  changed.update_columns(delay: 3)
  conflict = execute_relations(main, expected: "failed")
  raise "Local relation conflict ignored" unless conflict.error_message.include?("Local relation modified")
  changed.update_columns(delay: 2)
  puts "Relations smoke passed: two children and independent project, preview, ignore, private notes, cross-project rejection, four relations, delay and idempotence"
ensure
  Setting.cross_project_issue_relations = previous_cross
  projects.reverse_each do |project|
    MirrorMapping.where(project_id: project.id).delete_all
    MirrorPendingRelation.where(project_id: project.id).delete_all
    project.destroy!
  end
end
