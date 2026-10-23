# frozen_string_literal: true
# File: redmine_mirror/test/unit/issue_tags_test.rb
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

class MirrorIssueTagsTest < ActiveSupport::TestCase
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

  # The test Redmine has no Redmine Tags plugin: tags live in memory, by issue.
  class Adapter < RedmineMirror::Adapters::IssueTags
    attr_reader :tags
    def initialize; super; @tags = Hash.new { |hash, id| hash[id] = [] }; end
    def available?; true; end
    def read_tags(issue); @tags[issue.id]; end
    def write_tags(issue, names); @tags[issue.id] = names.dup; end
  end

  class Source
    attr_accessor :rows
    def initialize; @rows = [{ "id" => 101, "tags" => %w[urgent Backend] }, { "id" => 102, "tags" => [] }]; end
    def get(path, _params = {})
      raise "Unexpected #{path}" unless path == "projects/9/mirror/source/issue_tags.json"
      { "issue_tags" => @rows, "total_count" => @rows.size }
    end
  end

  def setup
    @project = Project.find(1)
    @store = Store.new
    @source = Source.new
    @adapter = Adapter.new
    # Source issues 101 and 102 were imported as local issues 1 and 2.
    @issues = { 101 => 1, 102 => 2 }
    @lookup = ->(key, id) { key == "issue_tracking" ? @issues[id] : nil }
  end

  def sync(apply: true)
    @adapter.records(@source, 9).map do |record|
      @adapter.synchronize(record, project_id: @project.id, mappings: {}, lookup: @lookup, store: @store, source: @source, apply: apply)
    end
  end

  def test_source_tags_are_added_and_an_issue_without_tags_needs_nothing
    assert_equal %w[update unchanged], sync(apply: false).map { |event| event[:action] }
    assert_empty @adapter.tags[1]
    assert_equal %w[update unchanged], sync.map { |event| event[:action] }
    assert_equal %w[Backend urgent], @adapter.tags[1]
    assert_nil @store.find("issue_tags", 102)
    assert_equal %w[unchanged unchanged], sync.map { |event| event[:action] }
  end

  def test_local_tags_are_kept_and_names_compare_without_case
    @adapter.tags[1] = %w[local URGENT]
    sync
    assert_equal %w[Backend local URGENT], @adapter.tags[1]
  end

  def test_mirrored_tag_removed_locally_is_a_conflict_unless_the_source_wins
    sync
    @adapter.tags[1] = %w[urgent]
    assert_match(/a tag added from the source was removed locally/, assert_raises(RedmineMirror::Error) { sync }.message)
    RedmineMirror::Policy.with(source_wins: true) { sync }
    assert_equal %w[Backend urgent], @adapter.tags[1]
  end

  # Mirror mode sets exactly the source tags, including an emptied list.
  def test_mirror_mode_removes_local_and_source_removed_tags
    @adapter.tags[2] = %w[local]
    RedmineMirror::Policy.with(source_wins: true) do
      sync
      assert_empty @adapter.tags[2]
      @source.rows.first["tags"] = %w[urgent]
      sync
    end
    assert_equal %w[urgent], @adapter.tags[1]
  end

  def test_tags_wait_for_their_issue_and_destination_needs_the_plugin
    @issues = { 102 => 2 }
    assert_equal "update", sync(apply: false).first[:action]
    assert_match(/Missing destination issue correspondence/, assert_raises(RedmineMirror::Error) { sync }.message)
    plain = RedmineMirror::Adapters::IssueTags.new
    skip "Redmine Tags is installed" if Issue.method_defined?(:tag_list)
    assert_not plain.available?
  end

  def test_refusals_name_the_lock_to_open
    source = Object.new
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path} (Mirror source: unavailable)"; end
    assert_match(/no Redmine Tags plugin/, assert_raises(RedmineMirror::Error) { @adapter.records(source, 9) }.message)
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}"; end
    assert_match(/install Redmine Mirror 1.0.0-beta.28/, assert_raises(RedmineMirror::Error) { @adapter.records(source, 9) }.message)
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 403 for GET #{path} (Mirror source: not_shared)"; end
    assert_match(/Share Tags/, assert_raises(RedmineMirror::Error) { @adapter.records(source, 9) }.message)
    def source.get(path, _params = {}); raise RedmineMirror::Error, "Redmine API returned HTTP 403 for GET #{path}"; end
    assert_match(/needs View issues/, assert_raises(RedmineMirror::Error) { @adapter.records(source, 9) }.message)
  end
end
