# frozen_string_literal: true
# File: redmine_mirror/test/unit/categories_test.rb
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

class MirrorCategoriesTest < ActiveSupport::TestCase
  fixtures :projects, :users, :issue_categories, :enabled_modules

  # A store of this project's rows, and of another mirrored project's rows.
  class Store
    def initialize(related = {}); @rows = {}; @related = related; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
    def find_related_mapping(key, id); @related[[key, id]]; end
  end

  def setup
    @adapter = RedmineMirror::Adapters::Categories.new
    @parent = Project.find(1)
    @child = Project.find(3) # a subproject of project 1
  end

  def with_sharing_column
    ActiveRecord::Base.connection.add_column :issue_categories, :sharing, :string, limit: 40
    IssueCategory.reset_column_information
    yield
  ensure
    ActiveRecord::Base.connection.remove_column :issue_categories, :sharing
    IssueCategory.reset_column_information
  end

  def run_record(record, store, project = @child)
    @adapter.synchronize(record, project_id: project.id, mappings: {}, lookup: ->(*) {}, store: store, source: nil, apply: true)
  end

  def test_mirror_source_gives_the_sharing_and_categories_of_other_projects_are_marked
    client = Object.new
    def client.get(path, _params = {})
      if path.include?("mirror/source")
        { "issue_categories" => [{ "id" => 9, "name" => "Own", "sharing" => "descendants" }, { "id" => 10, "name" => "Hidden from API" }] }
      else
        { "issue_categories" => [{ "id" => 9, "name" => "Own", "project" => { "id" => 7 } }, { "id" => 11, "name" => "Parent's", "project" => { "id" => 6 } }] }
      end
    end
    def client.each_record(_collection, _params)
      [{ "id" => 1, "category" => { "id" => 4, "name" => "Moved" } }].each
    end
    records = @adapter.records(client, 7).index_by { |record| record.fetch("id") }
    assert_equal [4, 9, 10, 11], records.keys
    assert_equal "descendants", records[9]["sharing"]
    refute records[9]["foreign"]
    refute records[10]["foreign"]
    assert records[11]["foreign"]
    assert records[4]["foreign"]
  end

  def test_sharing_is_written_only_where_the_destination_has_it
    record = { "id" => 9, "name" => "Shared", "sharing" => "descendants", "project" => { "id" => 7 } }
    refute @adapter.attributes(record, {}).key?("sharing")
    with_sharing_column do
      assert_equal "descendants", @adapter.attributes(record, {})["sharing"]
      refute @adapter.attributes(record.merge("sharing" => "system"), {}).key?("sharing")
      run_record(record, Store.new, @parent)
      assert_equal "descendants", IssueCategory.find_by!(project_id: @parent.id, name: "Shared")[:sharing]
    end
  end

  def test_a_category_shared_by_an_imported_parent_is_used_instead_of_a_copy
    with_sharing_column do
      shared = IssueCategory.create!(project: @parent, name: "Shared by the parent", sharing: "descendants")
      store = Store.new([["issue_categories", 11]].to_h { |key| [key, { "destination_id" => shared.id }] })
      record = { "id" => 11, "name" => "Shared by the parent", "project" => { "id" => 6 }, "foreign" => true }
      assert_no_difference -> { IssueCategory.count } do
        result = run_record(record, store)
        assert_equal [shared.id, "unchanged"], result.values_at(:destination_id, :action)
      end
      # Not shared with descendants: a copy is made in the subproject.
      shared.update_columns(sharing: "none")
      assert_difference -> { IssueCategory.where(project_id: @child.id).count }, 1 do
        assert_equal "create", run_record(record, store)[:action]
      end
    end
  end

  def test_without_the_parent_imported_a_used_category_is_copied
    record = { "id" => 12, "name" => "From elsewhere", "project" => { "id" => 6 }, "foreign" => true }
    assert_difference -> { IssueCategory.where(project_id: @child.id).count }, 1 do
      assert_equal "create", run_record(record, Store.new)[:action]
    end
  end
end
