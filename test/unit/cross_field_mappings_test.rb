# frozen_string_literal: true
# File: redmine_mirror/test/unit/cross_field_mappings_test.rb
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
# Verify a source field feeding the priority and the source priority going to a field.

require_relative "../test_helper"

class MirrorCrossFieldMappingsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :trackers, :projects_trackers,
    :issue_statuses, :issues, :enumerations, :versions, :issue_categories, :queries, :custom_fields, :custom_fields_projects,
    :custom_fields_trackers, :custom_values

  class Store
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
  end

  # Source field 950 "severity" feeds the priority; the source priorities 61/62 go to the
  # local list "Criticité".
  def setup
    @issue = Issue.find(2)
    @project = @issue.project
    @low, @high = IssuePriority.find(4), IssuePriority.find(6)
    @criticity = IssueCustomField.create!(name: "Criticité", field_format: "list", possible_values: %w[Mineure Majeure], is_for_all: true, is_filter: true, trackers: Tracker.all)
    @fields = RedmineMirror::Adapters::CustomFields.new
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example", source_project_id: 99)
    @setting.api_key = "unit-test-key"
    @setting.selected_modules = %w[issue_tracking issue_custom_fields]
    @setting.source_catalog = { "priority" => { "61" => "Normal", "62" => "Urgent" }, "custom_field" => { "950" => "severity", "951" => "Multiple" },
      "custom_field_definitions" => { "950" => { "field_format" => "list", "multiple" => false,
        "possible_values" => [{ "value" => "minor" }, { "value" => "blocker" }, { "value" => "cosmetic" }] },
        "951" => { "field_format" => "list", "multiple" => true, "possible_values" => [] } } }
    @setting.module_options = { @fields.key => { "value_mappings" => { "950" => { @fields.value_key("minor") => @low.id.to_s, @fields.value_key("blocker") => @high.id.to_s } },
      "priority_fallback" => @low.id.to_s, "priority_field" => @criticity.id.to_s, "priority_values" => { "61" => "Mineure", "62" => "Majeure" } } }
    @setting.save!
    @project.mirror_reference_mappings.create!(reference_type: "custom_field", source_id: 950, mode: "priority")
    @mappings = { "custom_field" => { "950" => "priority" }, "tracker" => { "1" => @issue.tracker_id }, "status" => { "1" => 1 } }
    @record = { "id" => 100, "project" => { "id" => 99 }, "subject" => "Remote", "tracker" => { "id" => 1 }, "status" => { "id" => 1 },
      "priority" => { "id" => 62 }, "custom_fields" => [{ "id" => 950, "value" => "blocker" }] }
  end

  def priority_of(record)
    RedmineMirror::TextFormat.reset_flags
    RedmineMirror::Adapters::Issues.new.payload(record, @project.id, @mappings, ->(*) {}).fetch("priority_id")
  end

  def test_the_field_feeds_the_priority_with_a_fallback
    assert_equal @high.id, priority_of(@record)
    @record["custom_fields"][0]["value"] = ""
    assert_equal @low.id, priority_of(@record)
    @record["custom_fields"] = []
    assert_equal @low.id, priority_of(@record)
    @record["custom_fields"] = [{ "id" => 950, "value" => "cosmetic" }]
    assert_equal @low.id, priority_of(@record)
    assert_match(/Missing value mapping for custom field source ID 950; the fallback priority/, RedmineMirror::TextFormat.warnings.first)
  end

  # Additive: without the custom fields module, the Priorities table applies again.
  def test_standard_priority_mapping_is_unchanged_otherwise
    @setting.update!(selected_modules: %w[issue_tracking])
    assert_raises(RedmineMirror::Error) { priority_of(@record) }
    assert_equal @high.id, RedmineMirror::Adapters::Issues.new.payload(@record, @project.id, @mappings.merge("priority" => { "62" => @high.id }), ->(*) {}).fetch("priority_id")
  end

  def test_the_source_priority_goes_to_the_field_and_the_feeding_field_is_not_a_field_value
    RedmineMirror::TextFormat.reset_flags
    values = @fields.imported_values(@record, project_id: @project.id, mappings: @mappings, lookup: ->(*) {}, issue: @issue)
    assert_equal({ @criticity.id.to_s => "Majeure" }, values)
    @record["priority"] = { "id" => 63 }
    assert_empty @fields.imported_values(@record, project_id: @project.id, mappings: @mappings, lookup: ->(*) {}, issue: @issue)
    assert_match(/Missing value mapping for source priority #63/, RedmineMirror::TextFormat.warnings.first)
  end

  def test_history_details_follow_the_crossed_fields
    record = { "user" => { "id" => 1 }, "created_on" => "2026-01-01T12:00:00Z", "notes" => "", "details" => [
      { "property" => "cf", "name" => "950", "old_value" => "minor", "new_value" => "blocker" },
      { "property" => "attr", "name" => "priority_id", "old_value" => "61", "new_value" => "62" }] }
    attributes = RedmineMirror::Adapters::Journals.new.imported_attributes(record, @mappings.merge("user" => { "1" => 1 }), lookup: ->(*) {}, project: @project)
    assert_equal [["attr", "priority_id", @low.id.to_s, @high.id.to_s], ["cf", @criticity.id.to_s, "Mineure", "Majeure"]], attributes.fetch("details")
    # Without a field receiving it, the source priority history is left out.
    @setting.update!(module_options: @setting.module_options.deep_merge(@fields.key => { "priority_field" => "" }))
    attributes = RedmineMirror::Adapters::Journals.new.imported_attributes(record, @mappings.merge("user" => { "1" => 1 }), lookup: ->(*) {}, project: @project)
    assert_equal [["attr", "priority_id", @low.id.to_s, @high.id.to_s]], attributes.fetch("details")
  end

  def test_configuration_checks_the_crossed_fields
    input = { "value_mappings" => {}, "priority_fallback" => @low.id.to_s, "priority_field" => @criticity.id.to_s, "priority_values" => { "61" => "Mineure" } }
    assert_equal input, @fields.configuration_options(input, @project)
    # The first save offers no choice yet: the default priority until one is chosen.
    assert_equal IssuePriority.default.id.to_s, @fields.configuration_options(input.except("priority_fallback"), @project).fetch("priority_fallback")
    assert_raises(RedmineMirror::Error) { @fields.configuration_options(input.merge("priority_fallback" => "999"), @project) }
    assert_raises(RedmineMirror::Error) { @fields.configuration_options(input.merge("priority_values" => { "99" => "Mineure" }), @project) }
    multiple = IssueCustomField.create!(name: "Multiple", field_format: "list", possible_values: %w[A], multiple: true, is_for_all: true)
    assert_raises(RedmineMirror::Error) { @fields.configuration_options(input.merge("priority_field" => multiple.id.to_s), @project) }
    # One source per destination: a source field already going to "Criticité".
    @project.mirror_reference_mappings.create!(reference_type: "custom_field", source_id: 951, mode: "existing", destination_id: @criticity.id)
    assert_raises(RedmineMirror::Error) { @fields.configuration_options(input, @project) }
  end

  def test_only_one_single_value_list_feeds_the_priority
    second = @project.mirror_reference_mappings.new(reference_type: "custom_field", source_id: 951, mode: "priority")
    assert_not second.valid?
    @project.mirror_reference_mappings.where(source_id: 950).delete_all
    assert_not second.valid?, "a multiple-value field cannot feed the priority"
    assert_not @project.mirror_reference_mappings.new(reference_type: "priority", source_id: 61, mode: "priority").valid?
  end

  def test_saved_queries_swap_the_crossed_filters_and_columns
    source = Object.new
    def source.get(_path, _params = {})
      { "queries" => [{ "id" => 1, "type" => "IssueQuery", "name" => "Crossed", "visibility" => 2, "user" => nil, "roles" => [],
        "filters" => { "cf_950" => { "operator" => "=", "values" => ["blocker"] }, "priority_id" => { "operator" => "=", "values" => ["61"] } },
        "column_names" => %w[subject priority cf_950], "sort_criteria" => [%w[cf_950 desc]], "group_by" => "priority", "options" => {} }] }
    end
    adapter = RedmineMirror::Adapters::ProjectQueries.new
    store = Store.new
    adapter.records(source, 99).each do |record|
      adapter.synchronize(record, project_id: @project.id, mappings: @mappings, lookup: ->(*) {}, store: store, source: source, apply: true)
    end
    query = Query.find(store.find("project_queries", 1).fetch("destination_id"))
    assert_equal({ operator: "=", values: [@high.id.to_s] }, query.filters["priority_id"])
    assert_equal({ operator: "=", values: ["Mineure"] }, query.filters["cf_#{@criticity.id}"])
    assert_equal [:subject, :"cf_#{@criticity.id}", :priority], query.column_names
    assert_equal [%w[priority desc]], query.sort_criteria
    assert_equal "cf_#{@criticity.id}", query.group_by
  end
end
