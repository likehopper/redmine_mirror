# frozen_string_literal: true
# File: redmine_mirror/test/unit/agile_test.rb
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

class MirrorAgileTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules, :trackers, :issue_statuses, :issues, :enumerations

  # Like DatabaseStore: every correspondence carries both fingerprints.
  class Store
    attr_reader :rows
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values)
      raise ActiveRecord::RecordInvalid, MirrorMapping.new if %w[destination_id source_fingerprint destination_fingerprint].any? { |field| values[field].blank? }
      @rows[[key, id]] = values
    end
  end

  # The test Redmine has no redmine_agile: sprints and agile data live in memory.
  Sprint = Struct.new(:id, :project_id, :name, :description, :start_date, :end_date, :status, :sharing)

  class Sprints < RedmineMirror::Adapters::AgileSprints
    attr_reader :sprints
    def initialize; super; @sprints = []; end
    def available?; true; end
    def find_sprint(project, id); @sprints.find { |sprint| sprint.id == id && sprint.project_id == project.id }; end
    def write_sprint(project, sprint, attributes)
      sprint ||= Sprint.new(@sprints.size + 1, project.id).tap { |row| @sprints << row }
      sprint.name, sprint.description, sprint.status, sprint.sharing = attributes.values_at("name", "description", "status", "sharing")
      sprint.start_date, sprint.end_date = Date.parse(attributes["start_date"]), Date.parse(attributes["end_date"])
      sprint
    end

    private

    def name_taken?(project, name, sprint)
      @sprints.any? { |row| row.project_id == project.id && row.name == name && row != sprint }
    end
  end

  class Issues < RedmineMirror::Adapters::AgileIssues
    attr_reader :data
    def initialize; super; @data = Hash.new { |hash, id| hash[id] = { "agile_sprint_id" => nil, "position" => nil, "story_points" => nil } }; end
    def available?; true; end
    def read_data(issue); @data[issue.id].dup; end
    def write_data(issue, attributes); @data[issue.id] = attributes.dup; end
  end

  class Source
    attr_accessor :scrum
    def initialize
      @scrum = { "sprints" => [
        { "id" => 11, "name" => "Sprint 1", "description" => "First", "start_date" => "2026-01-05", "end_date" => "2026-01-16", "status" => "closed", "shared" => true, "product_backlog" => false, "created_on" => "2026-01-02T09:00:00Z" },
        { "id" => 12, "name" => "Sprint 2", "description" => "", "start_date" => "2026-01-19", "end_date" => "2026-01-30", "status" => "locked", "shared" => false, "product_backlog" => false, "created_on" => "2026-01-02T09:00:00Z" },
        { "id" => 13, "name" => "Product backlog", "description" => nil, "start_date" => nil, "end_date" => nil, "status" => "open", "shared" => false, "product_backlog" => true, "created_on" => "2025-12-01T09:00:00Z" },
        { "id" => 14, "name" => "Sprint 1", "description" => "", "start_date" => "2026-02-02", "end_date" => "2026-02-13", "status" => "open", "shared" => false, "product_backlog" => false, "created_on" => "2026-01-30T09:00:00Z" }
      ], "issues" => [
        { "id" => 101, "sprint_id" => 11, "position" => 3, "story_points" => "5" },
        { "id" => 102, "sprint_id" => 13, "position" => 1, "story_points" => "0.5" },
        { "id" => 103, "sprint_id" => 99, "position" => 2, "story_points" => nil }
      ] }
    end

    def get(path, _params = {})
      raise "Unexpected #{path}" unless path == "projects/9/mirror/source/scrum.json"
      { "scrum" => @scrum }
    end
  end

  def setup
    @project = Project.find(1)
    @project.enable_module!(:agile)
    @store = Store.new
    @source = Source.new
    @sprints = Sprints.new
    @issues = Issues.new
    # Source issues 101 to 103 were imported as local issues 1 to 3; sprint 99 belongs to
    # another source project, not synchronized yet.
    @issue_ids = { 101 => 1, 102 => 2, 103 => 3 }
    @lookup = lambda do |key, id|
      key == "issue_tracking" ? @issue_ids[id] : @store.find(key, id)&.fetch("destination_id")
    end
  end

  def sync(adapter, apply: true)
    adapter.records(@source, 9).map do |record|
      adapter.synchronize(record, project_id: @project.id, mappings: {}, lookup: @lookup, store: @store, source: @source, apply: apply)
    rescue RedmineMirror::Error => error
      { action: "error", reason: error.message }
    end
  end

  def test_scrum_sprints_become_agile_sprints
    assert_equal %w[create create create create], sync(@sprints, apply: false).map { |event| event[:action] }
    assert_empty @sprints.sprints
    sync(@sprints)
    first, locked, backlog, duplicate = @sprints.sprints
    assert_equal ["Sprint 1", "First", 2, 1, Date.new(2026, 1, 5)], [first.name, first.description, first.status, first.sharing, first.start_date]
    # A locked sprint is not finished: open.
    assert_equal [0, 0], [locked.status, locked.sharing]
    # A product backlog without dates takes its creation date.
    assert_equal ["Product backlog", Date.new(2025, 12, 1), Date.new(2025, 12, 1)], [backlog.name, backlog.start_date, backlog.end_date]
    # Names are unique per project: the second "Sprint 1" gets its source number.
    assert_equal "Sprint 1 (14)", duplicate.name
    assert_equal %w[unchanged unchanged unchanged unchanged], sync(@sprints).map { |event| event[:action] }
  end

  def test_issues_get_sprint_position_and_rounded_story_points
    sync(@sprints)
    events = sync(@issues)
    assert_equal %w[update update error], events.map { |event| event[:action] }
    assert_match(/Missing sprint correspondence for source issue #103 \(sprint #99\)/, events.last[:reason])
    assert_equal({ "agile_sprint_id" => 1, "position" => 3, "story_points" => 5 }, @issues.data[1])
    # Agile story points are whole numbers: 0.5 becomes 1.
    assert_equal({ "agile_sprint_id" => 3, "position" => 1, "story_points" => 1 }, @issues.data[2])
    assert_equal %w[unchanged unchanged error], sync(@issues).map { |event| event[:action] }
  end

  def test_local_changes_are_conflicts_unless_the_source_wins
    sync(@sprints)
    sync(@issues)
    @sprints.sprints.first.name = "Renamed locally"
    assert_match(/Local modification detected for sprint "Sprint 1"/, sync(@sprints).first[:reason])
    RedmineMirror::Policy.with(source_wins: true) { sync(@sprints) }
    # The duplicate keeps its number: it never takes the name of a sprint renamed locally.
    assert_equal ["Sprint 1", "Sprint 1 (14)"], [@sprints.sprints.first.name, @sprints.sprints.last.name]
    @issues.data[1]["position"] = 42
    assert_match(/Local modification detected for the agile data of issue #1/, sync(@issues).first[:reason])
    RedmineMirror::Policy.with(source_wins: true) { sync(@issues) }
    assert_equal 3, @issues.data[1]["position"]
  end

  # Overlapping sprints and closed sprints with open issues are kept; other refusals stay.
  def test_only_rules_scrum_did_not_have_are_tolerated
    I18n.backend.store_translations(I18n.locale, label_agile_sprint_errors_crossed: "Sprint dates are cross another existed sprint",
      label_agile_sprint_errors_open_issues: "Sprint has open issues")
    assert_equal ["Name has already been taken"], RedmineMirror::Adapters::Agile.blocking_errors(
      ["Sprint dates are cross another existed sprint", "Name has already been taken", "Sprint has open issues"])
  end

  def test_story_points_conversion
    assert_equal [nil, nil, 3, 1, 2, 1], [nil, " ", "3", "0.5", "1,5", 1].map { |value| RedmineMirror::Adapters::Agile.story_points(value) }
    assert_nil RedmineMirror::Adapters::Agile.story_points("XL")
  end

  def test_refusals_and_missing_plugin
    source = Object.new
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path} (Mirror source: unavailable)"; end
    assert_match(/no Scrum plugin/, assert_raises(RedmineMirror::Error) { @sprints.records(source, 9) }.message)
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}"; end
    assert_match(/install Redmine Mirror 1.0.0-beta.30/, assert_raises(RedmineMirror::Error) { @issues.records(source, 9) }.message)
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 403 for GET #{path} (Mirror source: not_shared)"; end
    assert_match(/Share Scrum sprints/, assert_raises(RedmineMirror::Error) { @sprints.records(source, 9) }.message)
    @project.disable_module!(:agile)
    assert_match(/Enable the Agile module/, sync(@sprints).first[:reason])
    skip "redmine_agile is installed" if RedmineMirror::Adapters::Agile.available?
    assert_not RedmineMirror::Adapters::AgileSprints.new.available?
  end
end
