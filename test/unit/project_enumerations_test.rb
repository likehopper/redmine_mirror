# frozen_string_literal: true
# File: redmine_mirror/test/unit/project_enumerations_test.rb
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

class MirrorProjectEnumerationsTest < ActiveSupport::TestCase
  include MirrorFakeProjectEnumerations
  fixtures :projects, :users, :trackers, :projects_trackers, :enabled_modules

  class Store
    def initialize(related = {}); @rows = {}; @related = related; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
    def find_related_mapping(key, id); @related[[key, id]]; end
  end

  def setup
    install_fake_project_enumerations
    @adapter = RedmineMirror::Adapters::ProjectEnumerations.new
    @project = Project.find(1)
    @field = enumeration_field("Client site")
  end

  def teardown
    remove_fake_project_enumerations
  end

  def client(rows)
    client = Object.new
    client.define_singleton_method(:get) { |_path, _params = {}| { "project_enumerations" => rows } }
    client
  end

  def row(id, value, field_id: 61, type: "IssueCustomField", **extra)
    { "id" => id, "custom_field" => { "id" => field_id, "name" => "Site", "field_format" => "project_enumeration", "type" => type },
      "value" => value, "status" => "open", "sharing" => "none", "position" => id }.merge(extra.transform_keys(&:to_s))
  end

  def test_available_only_with_the_plugin_and_lists_issue_fields_only
    assert @adapter.available?
    rows = [row(5, "Lyon"), row(4, "Paris"), row(6, "Hours", field_id: 62, type: "TimeEntryCustomField")]
    records = @adapter.records(client(rows), 9)
    assert_equal [4, 5], records.map { |record| record.fetch("id") }
    assert_equal [9], records.map { |record| record.dig("project", "id") }.uniq
    assert_equal({ "custom_field" => [{ "id" => 61, "name" => "Site", "field_format" => "project_enumeration", "multiple" => false }] },
      @adapter.catalog_references(client(rows), 9))
    remove_fake_project_enumerations
    refute @adapter.available?
  ensure
    install_fake_project_enumerations unless Object.const_defined?(:ProjectEnumeration)
  end

  def test_refusals_say_what_the_source_must_change
    refused = Object.new
    def refused.get(path, _params = {})
      raise RedmineMirror::Error, "Redmine API returned HTTP 403 for GET #{path} (Mirror source: not_shared)"
    end
    error = assert_raises(RedmineMirror::Error) { @adapter.records(refused, 9) }
    assert_match "Share Project enumerations", error.message
  end

  def test_creates_enumerations_in_the_mapped_field_and_translates_issue_values
    mappings = { "custom_field" => { "61" => @field.id.to_s } }
    store = Store.new
    record = { "project" => { "id" => 9 } }.merge(row(4, "Paris", sharing: "descendants", status: "locked"))
    event = @adapter.synchronize(record, project_id: @project.id, mappings: mappings, lookup: ->(*) {}, store: store, source: nil, apply: true)
    assert_equal "create", event[:action]
    enumeration = ProjectEnumeration.find(event[:destination_id])
    assert_equal [@project.id, @field.id, "Paris", "locked", "descendants", 4],
      enumeration.attributes.values_at("project_id", "custom_field_id", "value", "status", "sharing", "position")
    again = @adapter.synchronize(record, project_id: @project.id, mappings: mappings, lookup: ->(*) {}, store: store, source: nil, apply: true)
    assert_equal "unchanged", again[:action]
    # An issue value is the enumeration ID: translated through the correspondence.
    fields = RedmineMirror::Adapters::CustomFields.new
    lookup = ->(key, id) { key == "project_enumerations" && id == 4 ? enumeration.id : nil }
    translated = fields.translate_value("4", source_id: 61, field: @field, definition: { "field_format" => "project_enumeration", "multiple" => false },
      options: {}, mappings: mappings, lookup: lookup)
    assert_equal enumeration.id.to_s, translated
    error = assert_raises(RedmineMirror::Error) do
      fields.translate_value("7", source_id: 61, field: @field, definition: { "field_format" => "project_enumeration" }, options: {}, mappings: mappings, lookup: lookup)
    end
    assert_match "select the Project enumerations module", error.message
  end

  def test_an_ignored_field_leaves_its_enumerations_and_a_wrong_field_is_refused
    assert_equal "custom_field", @adapter.ignored_reference(row(4, "Paris"), { "custom_field" => { "61" => "ignore" } })
    assert_nil @adapter.ignored_reference(row(4, "Paris"), { "custom_field" => { "61" => @field.id.to_s } })
    list = IssueCustomField.create!(name: "Plain list", field_format: "list", possible_values: ["a"], is_for_all: true)
    error = assert_raises(RedmineMirror::Error) { @adapter.attributes(row(4, "Paris"), { "custom_field" => { "61" => list.id.to_s } }) }
    assert_match "project enumeration field", error.message
  end
end
