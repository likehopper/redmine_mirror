# frozen_string_literal: true
# File: redmine_mirror/test/environment/custom_fields_smoke.rb
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
User.current = User.find_by!(login: "admin")
project = Project.create!(name: "CF smoke", identifier: "cf-smoke-#{SecureRandom.hex(4)}", enabled_module_names: %w[mirror issue_tracking])
project.trackers = Tracker.all
Member.create!(project: project, user: User.find_by!(login: "alice"), roles: [Role.find_by!(name: "Manager")])
created_fields = []
begin
  source_id = original.source_client.get("projects/mirror-custom-fields-demo.json").fetch("project").fetch("id")
  setting = MirrorProjectSetting.new(project: project, source_url: original.source_url, source_project_id: source_id)
  setting.api_key = original.api_key
  setting.selected_modules = %w[project_versions issue_custom_fields issue_journals]
  setting.source_catalog = RedmineMirror::SourceCatalog.new(client: setting.source_client, project_id: source_id, adapters: setting.adapters).fetch
  setting.save!
  options = {}
  setting.source_catalog.fetch("custom_field").each do |id, name|
    definition = setting.source_catalog.fetch("custom_field_definitions").fetch(id)
    field = IssueCustomField.create!(name: "Local #{name} #{SecureRandom.hex(2)}", field_format: definition.fetch("field_format"),
      multiple: definition.fetch("multiple"), is_for_all: false, visible: true, editable: true, trackers: Tracker.all, projects: [project],
      possible_values: definition["field_format"] == "list" ? ["Local A", "Local B"] : [])
    created_fields << field
    project.reload
    # Exercise creation with a required field that has no local default.
    field.update!(is_required: true) if name.end_with?("Text")
    project.mirror_reference_mappings.create!(reference_type: "custom_field", source_id: id, destination_id: field.id, mode: "existing")
    if field.field_format == "list"
      options[id] = definition.fetch("possible_values").to_h { |value| [RedmineMirror::Adapters::CustomFields.new.value_key(value.fetch("value")), value.fetch("value").sub("Remote", "Local")] }
    end
  end
  setting.source_catalog.each do |kind, values|
    next unless %w[tracker status priority user].include?(kind)
    values.each do |id, name|
      target = kind == "user" ? User.find_by!(login: "alice").id : { "tracker" => Tracker, "status" => IssueStatus, "priority" => IssuePriority }.fetch(kind).find_by!(name: name).id
      project.mirror_reference_mappings.create!(reference_type: kind, source_id: id, destination_id: target, mode: "existing")
    end
  end
  setting.update!(module_options: { "issue_custom_fields" => { "value_mappings" => options } })
  execute = lambda do |apply|
    run = RedmineMirror::Synchronization.enqueue(setting, apply: apply, trigger: "operator", user: User.current)
    RedmineMirror::Synchronization.execute(run)
    raise "CF import failed: #{run.reload.error_message}" unless run.status == "succeeded"
    run
  end
  execute.call(false)
  raise "Preview wrote issues" if project.issues.exists?
  execute.call(true)
  raise "Issue count" unless project.issues.count == 2
  created_fields.each do |field|
    project.issues.each do |issue|
      value = issue.custom_field_value(field)
      expected = case field.field_format
        when "string" then "Updated text"
        when "list" then ["Local B"]
        when "int" then "42"
        when "date" then "2026-01-02"
        when "bool" then "1"
        when "user" then User.find_by!(login: "alice").id.to_s
        when "version" then project.versions.find_by!(name: "Source custom version").id.to_s
        end
      raise "CF mismatch #{field.field_format}: #{value.inspect}" unless value == expected
    end
  end
  imported = project.mirror_sync_runs.last.log_events.select { |event| event["module"] == "issue_journals" }.map { |event| Journal.find(event.fetch("destination_id")) }
  fixture_journals = imported.select { |journal| journal.notes == "Custom field history fixture" }
  source_journals = RedmineMirror::Adapters::Journals.new.records(setting.source_client, source_id).to_a
  source_detail_count = source_journals.sum { |journal| journal.fetch("details", []).count { |detail| detail["property"] == "cf" } }
  raise "Custom history missing" unless fixture_journals.size == 2 && imported.size == source_journals.size && imported.sum { |journal| journal.details.where(property: "cf").count } == source_detail_count && source_detail_count >= 4
  list_field = created_fields.find { |field| field.field_format == "list" }
  raise "Historical list value not translated" unless imported.any? { |journal| journal.details.exists?(property: "cf", prop_key: list_field.id.to_s, old_value: "Local A", value: nil) }
  raise "Private custom history lost" unless fixture_journals.count(&:private_notes) == 1
  last = execute.call(true)
  raise "Not idempotent" unless last.log_events.all? { |event| event["action"] == "unchanged" }
  issue = project.issues.first
  text = created_fields.find { |field| field.field_format == "string" }
  issue.custom_field_values = { text.id.to_s => "Local conflict" }
  issue.save!
  run = RedmineMirror::Synchronization.enqueue(setting, apply: true, trigger: "operator", user: User.current)
  RedmineMirror::Synchronization.execute(run)
  raise "CF conflict not detected" unless run.reload.status == "failed" && run.error_message.include?("Local modification")
  puts "Custom fields smoke passed: required field creation, seven formats, values, history, privacy, preview, idempotence and conflict"
ensure
  MirrorMapping.where(project_id: project.id).delete_all
  project.destroy!
  created_fields.each(&:destroy!)
end
