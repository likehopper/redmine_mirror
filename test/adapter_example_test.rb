# frozen_string_literal: true
# File: redmine_mirror/test/adapter_example_test.rb
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

require "minitest/autorun"
require_relative "../lib/redmine_mirror"
require_relative "../doc/examples/project_notes"

class MirrorAdapterExampleTest < Minitest::Test
  # A small API double follows the documented fictional notes contract.
  class NotesApi
    attr_reader :notes, :writes

    def initialize(notes = [])
      @notes = notes
      @writes = []
    end

    def each_record(collection, _filters)
      raise "Unexpected collection" unless collection == "project_notes"
      notes.each
    end

    def get(path)
      return { "project" => { "id" => 42 } } if path.start_with?("projects/")
      record_id = Integer(path.split("/").last.delete_suffix(".json"))
      { "project_note" => notes.find { |note| note.fetch("id") == record_id } }
    end

    def create(path, payload)
      raise "Unexpected creation path" unless path == "project_notes.json"
      attributes = payload.fetch("project_note").dup
      record = attributes.merge("id" => 900, "project" => { "id" => attributes.delete("project_id") })
      notes << record
      writes << :create
      { "project_note" => record }
    end

    def update(path, payload)
      attributes = payload.fetch("project_note").dup
      attributes.delete("project_id")
      get(path).fetch("project_note").merge!(attributes)
      writes << :update
      {}
    end
  end

  class MappingStore
    def initialize; @mappings = {}; end
    def find(module_key, source_id); @mappings[[module_key, source_id]]; end
    def save(module_key, source_id, attributes); @mappings[[module_key, source_id]] = attributes; end
  end

  def setup
    @record = { "id" => 7, "project" => { "id" => 42 }, "title" => "Runbook", "body" => "Restart procedure" }
    @source = NotesApi.new([@record])
    @destination = NotesApi.new
    @store = MappingStore.new
    registry = RedmineMirror::Registry.new
    registry.register(RedmineMirror::Adapters::ProjectNotes.new)
    @runner = RedmineMirror::Runner.new(source: @source, destination: @destination, store: @store, registry: registry)
    @config = { "source_project_id" => 42, "destination_project_id" => 84, "modules" => ["project_notes"] }
  end

  def test_preview_does_not_write_or_create_correspondences
    events = @runner.run(@config)
    assert_equal "create", events.first.fetch(:action)
    assert_empty @destination.writes
    assert_nil @store.find("project_notes", 7)
  end

  def test_create_uses_destination_project_and_repeat_is_unchanged
    @runner.run(@config, apply: true)
    assert_equal 84, @destination.notes.first.fetch("project").fetch("id")
    assert_equal 900, @store.find("project_notes", 7).fetch("destination_id")
    assert_equal "unchanged", @runner.run(@config, apply: true).first.fetch(:action)
    assert_equal [:create], @destination.writes
  end

  def test_source_update_changes_managed_values
    @runner.run(@config, apply: true)
    @record["body"] = "Revised procedure"
    assert_equal "update", @runner.run(@config, apply: true).first.fetch(:action)
    assert_equal "Revised procedure", @destination.notes.first.fetch("body")
    assert_equal [:create, :update], @destination.writes
  end

  def test_local_edit_stops_import_without_overwriting
    @runner.run(@config, apply: true)
    @destination.notes.first["title"] = "Local runbook"
    error = assert_raises(RedmineMirror::Error) { @runner.run(@config, apply: true) }
    assert_match(/Local modification detected/, error.message)
    assert_equal "Local runbook", @destination.notes.first.fetch("title")
    assert_equal [:create], @destination.writes
  end

  def test_other_project_records_are_not_imported
    @source.notes << @record.merge("id" => 8, "project" => { "id" => 43 })
    events = @runner.run(@config, apply: true)
    assert_equal [7], events.map { |event| event.fetch(:source_id) }
    assert_nil @store.find("project_notes", 8)
  end
end
