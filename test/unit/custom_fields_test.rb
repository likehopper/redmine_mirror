# frozen_string_literal: true
# File: redmine_mirror/test/unit/custom_fields_test.rb
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
# Verify Mirror behavior, project boundaries and repeatable synchronization.

require_relative "../test_helper"

class MirrorCustomFieldsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :issues, :issue_statuses, :trackers, :enumerations, :enabled_modules, :custom_fields, :custom_values

  class Store
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
  end

  def setup
    @issue = Issue.find(2)
    @field = IssueCustomField.create!(name: "Mirror text", field_format: "string", is_for_all: true, trackers: Tracker.all)
    @list = IssueCustomField.create!(name: "Mirror list", field_format: "list", possible_values: ["Local A", "Local B"], multiple: true, is_for_all: true, trackers: Tracker.all)
    @setting = MirrorProjectSetting.new(project: @issue.project, source_url: "https://source.example", source_project_id: 99)
    @setting.api_key = "unit-test-key"
    @setting.selected_modules = ["issue_custom_fields"]
    @setting.source_catalog = { "custom_field" => { "900" => "Text", "901" => "List" }, "custom_field_definitions" => {
      "900" => { "field_format" => "string", "multiple" => false },
      "901" => { "field_format" => "list", "multiple" => true, "possible_values" => [{ "value" => "Remote A", "label" => "Remote A" }] } } }
    @adapter = RedmineMirror::Adapters::CustomFields.new
    @setting.module_options = { @adapter.key => { "value_mappings" => { "901" => { @adapter.value_key("Remote A") => "Local B" } } } }
    @setting.save!
    @store = Store.new
    @mappings = { "custom_field" => { "900" => @field.id, "901" => @list.id } }
    @lookup = ->(key, id) { @issue.id if key == "issue_tracking" && id == 100 }
    @record = { "id" => 100, "custom_fields" => [{ "id" => 900, "value" => "Remote text" }, { "id" => 901, "value" => ["Remote A"] }] }
  end

  def run_adapter(apply: true)
    @adapter.synchronize(@record, project_id: @issue.project_id, mappings: @mappings, lookup: @lookup, store: @store, source: nil, apply: apply)
  end

  def test_preview_values_dates_idempotence_source_update_and_local_conflict
    before = @issue.reload.updated_on
    run_adapter(apply: false)
    assert_nil @issue.reload.custom_field_value(@field)
    run_adapter
    assert_equal "Remote text", @issue.reload.custom_field_value(@field)
    assert_equal ["Local B"], @issue.custom_field_value(@list)
    assert_equal before, @issue.updated_on
    assert_equal "unchanged", run_adapter[:action]
    @record["custom_fields"][0]["value"] = "Updated remote"
    run_adapter
    assert_equal "Updated remote", @issue.reload.custom_field_value(@field)
    @issue.custom_field_values = { @field.id.to_s => "Local edit" }
    @issue.save!
    assert_raises(RedmineMirror::Error) { run_adapter }
  end

  def test_unmapped_field_value_and_incompatible_format_are_warnings
    warnings = lambda do
      RedmineMirror::TextFormat.reset_flags
      @adapter.imported_values(@record, project_id: @issue.project_id, mappings: @mappings, lookup: @lookup, issue: @issue)
      RedmineMirror::TextFormat.warnings
    end
    @mappings["custom_field"].delete("900")
    assert_match(/Missing custom_field mapping for source ID 900/, warnings.call.first)
    @mappings["custom_field"]["900"] = @field.id
    @record["custom_fields"][1]["value"] = ["Missing value"]
    assert_match(/Missing value mapping for custom field source ID 901/, warnings.call.first)
    @record["custom_fields"][1]["value"] = ["Remote A"]
    @mappings["custom_field"]["900"] = @list.id
    assert_match(/incompatible formats or multiplicity/, warnings.call.first)
  end

  def test_history_remaps_field_and_list_values
    record = { "user" => { "id" => 7 }, "created_on" => "2026-01-01T12:00:00Z", "notes" => "Historical change",
      "details" => [{ "property" => "cf", "name" => "901", "old_value" => nil, "new_value" => "Remote A" }] }
    attributes = RedmineMirror::Adapters::Journals.new.imported_attributes(record,
      @mappings.merge("user" => { "7" => "anonymous" }), lookup: @lookup, project: @issue.project)
    assert_equal [["cf", @list.id.to_s, nil, "Local B"]], attributes.fetch("details")
    assert_equal User.anonymous.id, attributes.fetch("user_id")
  end

  def test_field_outside_project_is_skipped_and_duplicate_targets_are_rejected
    outside = IssueCustomField.create!(name: "Outside", field_format: "string", trackers: Tracker.all)
    @mappings["custom_field"]["900"] = outside.id
    RedmineMirror::TextFormat.reset_flags
    run_adapter
    assert_match(/not enabled in this project/, RedmineMirror::TextFormat.warnings.first)
    @mappings["custom_field"]["900"] = @field.id
    @record["custom_fields"] << @record["custom_fields"].first.dup
    assert_raises(RedmineMirror::Error) { run_adapter }
  end
  def test_existing_local_values_are_not_overwritten_on_first_import
    @issue.custom_field_values = { @field.id.to_s => "Pre-existing local value" }
    @issue.save!
    assert_raises(RedmineMirror::Error) { run_adapter }
    assert_equal "Pre-existing local value", @issue.reload.custom_field_value(@field)
  end

  def test_invalid_integer_is_rejected_without_writes
    number = IssueCustomField.create!(name: "Mirror integer", field_format: "int", is_for_all: true, trackers: Tracker.all)
    @setting.source_catalog = @setting.source_catalog.deep_merge("custom_field" => { "902" => "Integer" },
      "custom_field_definitions" => { "902" => { "field_format" => "int", "multiple" => false } })
    @setting.save!
    @mappings["custom_field"]["902"] = number.id
    @record["custom_fields"] << { "id" => 902, "value" => "invalid integer" }
    RedmineMirror::TextFormat.reset_flags
    run_adapter
    assert_nil @issue.reload.custom_field_value(number)
    assert(RedmineMirror::TextFormat.warnings.any? { |warning| warning.include?("Invalid value for custom field source ID 902") })
  end

  # A non-administrator source key cannot read definitions: fields and their values
  # are observed in the issues and history, formats come from the destination fields.
  def test_observed_mode_builds_the_catalog_from_issues_and_history
    client = Object.new
    def client.each_record(_collection, _params)
      [{ "id" => 7, "project" => { "id" => 99 }, "custom_fields" => [
        { "id" => 901, "name" => "Remote list", "multiple" => true, "value" => ["Remote A"] },
        { "id" => 902, "name" => "Remote number", "value" => "12" }] }].each
    end
    def client.get(path, _params = {})
      raise RedmineMirror::Error, "Redmine API returned HTTP 403 for GET #{path}" if path == "custom_fields.json"
      { "issue" => { "journals" => [{ "details" => [{ "property" => "cf", "name" => "901", "old_value" => "Remote old", "new_value" => "Remote A" }] }] } }
    end
    catalog = @adapter.catalog_references(client, 99)
    list, number = catalog.fetch("custom_field").sort_by { |field| field.fetch("id") }
    assert_equal ["Remote list", true, nil, true], list.values_at("name", "multiple", "field_format", "observed")
    assert_equal ["Remote A", "Remote old"], list.fetch("possible_values").map { |value| value.fetch("value") }.sort
    assert_equal [false, ["12"]], [number.fetch("multiple"), number.fetch("possible_values").map { |value| value.fetch("value") }]
    refute catalog.key?("user")
  end

  def test_observed_values_follow_the_destination_format
    observed = { "field_format" => nil, "observed" => true, "multiple" => true }
    options = { "value_mappings" => { "901" => { @adapter.value_key("Remote A") => "Local A" } } }
    assert_equal ["Local A"], @adapter.translate_value(["Remote A"], source_id: 901, field: @list,
      definition: observed, options: options, mappings: @mappings, lookup: @lookup)
    number = IssueCustomField.create!(name: "Mirror observed integer", field_format: "int", is_for_all: true, trackers: Tracker.all)
    single = observed.merge("multiple" => false)
    assert_equal "42", @adapter.translate_value("42", source_id: 902, field: number, definition: single, options: {}, mappings: @mappings, lookup: @lookup)
    error = assert_raises(RedmineMirror::Error) do
      @adapter.translate_value("not a number", source_id: 902, field: number, definition: single, options: {}, mappings: @mappings, lookup: @lookup)
    end
    assert_includes error.message, "Invalid value for custom field source ID 902"
    # Multiplicity is known from the issues and must still match.
    assert_raises(RedmineMirror::Error) do
      @adapter.translate_value(["42"], source_id: 902, field: number, definition: observed, options: {}, mappings: @mappings, lookup: @lookup)
    end
  end

  # A value that cannot be written is skipped with a warning; the issue still synchronizes.
  def test_unwritable_values_are_skipped_with_a_warning
    @list.update!(trackers: [Tracker.where.not(id: @issue.tracker_id).first!])
    RedmineMirror::TextFormat.reset_flags
    values = @adapter.imported_values(@record, project_id: @issue.project_id, mappings: @mappings, lookup: @lookup, issue: @issue)
    assert_equal [@field.id.to_s], values.keys
    assert_match(/Custom field "Mirror list" is not enabled for destination tracker/, RedmineMirror::TextFormat.warnings.first)
    assert_equal "update", run_adapter[:action]
    assert_equal "Remote text", @issue.reload.custom_field_value(@field)
  end

  def test_enumeration_values_use_local_ids
    field = IssueCustomField.create!(name: "Mirror enumeration", field_format: "enumeration", is_for_all: true, trackers: Tracker.all)
    entry = field.enumerations.create!(name: "Local option", position: 1)
    translated = @adapter.translate_value("123", source_id: 902, field: field,
      definition: { "field_format" => "enumeration", "multiple" => false },
      options: { "value_mappings" => { "902" => { @adapter.value_key("123") => entry.id.to_s } } }, mappings: @mappings, lookup: @lookup)
    assert_equal entry.id.to_s, translated
  end

  def test_field_order_does_not_change_fingerprints
    assert_equal @adapter.digest("1" => "a", "2" => ["b"]), @adapter.digest("2" => ["b"], "1" => "a")
  end

  def test_history_requires_selected_custom_field_adapter
    @setting.selected_modules = ["issue_journals"]
    @setting.save!
    record = { "user" => { "id" => 7 }, "created_on" => "2026-01-01T12:00:00Z", "details" => [
      { "property" => "cf", "name" => "900", "old_value" => nil, "new_value" => "Historical value" }] }
    RedmineMirror::TextFormat.reset_flags
    attributes = RedmineMirror::Adapters::Journals.new.imported_attributes(record,
      @mappings.merge("user" => { "7" => "anonymous" }), project: @issue.project, lookup: @lookup)
    assert_empty attributes.fetch("details")
    assert_match(/Select the custom fields module/, RedmineMirror::TextFormat.warnings.first)
  end

  def test_ignored_field_skips_values_and_history_but_keeps_notes
    @mappings["custom_field"]["901"] = "ignore"
    run_adapter
    assert_equal "Remote text", @issue.reload.custom_field_value(@field)
    assert_empty Array(@issue.custom_field_value(@list)).compact
    record = { "user" => { "id" => 7 }, "created_on" => "2026-01-01T12:00:00Z", "notes" => "Keep note", "private_notes" => true,
      "details" => [{ "property" => "cf", "name" => "901", "new_value" => "Unmapped list value" }] }
    attributes = RedmineMirror::Adapters::Journals.new.imported_attributes(record,
      @mappings.merge("user" => { "7" => "anonymous" }), project: @issue.project, lookup: @lookup)
    assert_empty attributes.fetch("details")
    assert_equal "Keep note", attributes.fetch("notes")
    assert attributes.fetch("private_notes")
  end

end
