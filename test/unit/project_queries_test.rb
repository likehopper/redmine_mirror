# frozen_string_literal: true
# File: redmine_mirror/test/unit/project_queries_test.rb
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

class MirrorProjectQueriesTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :trackers, :projects_trackers,
    :issue_statuses, :issues, :enumerations, :versions, :issue_categories, :queries, :custom_fields, :custom_fields_projects,
    :custom_fields_trackers

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

  def query(id, type: "IssueQuery", visibility: 2, user: { "id" => 7, "name" => "Remote" }, filters: {}, roles: [], **rest)
    { "id" => id, "type" => type, "name" => "Query #{id}", "visibility" => visibility, "user" => user, "roles" => roles,
      "filters" => filters, "column_names" => [], "sort_criteria" => [], "group_by" => nil, "options" => {} }.merge(rest.transform_keys(&:to_s))
  end

  class Source
    attr_accessor :queries
    def get(path, _params = {})
      raise "Unexpected #{path}" unless path == "projects/9/mirror/source/queries.json"
      { "queries" => @queries, "total_count" => @queries.size }
    end
  end

  def setup
    @project = Project.find(1)
    @store = Store.new
    @source = Source.new
    @adapter = RedmineMirror::Adapters::ProjectQueries.new
    # Source statuses 11/12, tracker 21, users 7/8, version 31 and role 41 have local equivalents.
    @mappings = { "status" => { "11" => "1", "12" => "ignore" }, "tracker" => { "21" => "2" },
      "user" => { "7" => "2", "8" => "anonymous" }, "role" => { "41" => "2" } }
    @lookup = ->(key, id) { { ["project_versions", 31] => 2 }[[key, id]] }
  end

  def sync(apply: true)
    @adapter.records(@source, 9).map do |record|
      @adapter.synchronize(record, project_id: @project.id, mappings: @mappings, lookup: @lookup, store: @store, source: @source, apply: apply)
    end
  end

  def imported(source_id)
    Query.find(@store.find("project_queries", source_id).fetch("destination_id"))
  end

  def test_filters_columns_sorts_and_groups_are_translated
    @source.queries = [query(1, filters: { "status_id" => { "operator" => "=", "values" => ["11"] },
      "tracker_id" => { "operator" => "=", "values" => ["21"] }, "fixed_version_id" => { "operator" => "=", "values" => ["31"] },
      "assigned_to_id" => { "operator" => "=", "values" => %w[me 7] }, "subject" => { "operator" => "~", "values" => ["login"] } },
      column_names: %w[subject status plugin_column], sort_criteria: [%w[priority desc], %w[cf_999 asc]], group_by: "tracker")]
    assert_equal %w[create], sync(apply: false).map { |event| event[:action] }
    assert_no_difference("Query.count") { sync(apply: false) }
    sync
    local = imported(1)
    assert_equal [IssueQuery, @project.id, 2, Query::VISIBILITY_PUBLIC], [local.class, local.project_id, local.user_id, local.visibility]
    assert_equal({ operator: "=", values: ["1"] }, local.filters["status_id"])
    assert_equal ["2"], local.filters.dig("tracker_id", :values)
    assert_equal ["2"], local.filters.dig("fixed_version_id", :values)
    assert_equal %w[me 2], local.filters.dig("assigned_to_id", :values)
    assert_equal ["login"], local.filters.dig("subject", :values)
    # A column, sort or group that does not exist here is left out.
    assert_equal %i[subject status], local.column_names.first(2)
    assert_not_includes local.column_names, :plugin_column
    assert_equal [%w[priority desc]], local.sort_criteria
    assert_equal "tracker", local.group_by
    assert_equal %w[unchanged], sync.map { |event| event[:action] }
  end

  # A query with a filter that cannot be translated is not created.
  def test_untranslatable_filters_leave_the_query_out
    @source.queries = [
      query(2, filters: { "status_id" => { "operator" => "=", "values" => ["12"] } }),
      query(3, filters: { "assigned_to_id" => { "operator" => "=", "values" => ["8"] } }),
      query(4, filters: { "subproject_id" => { "operator" => "=", "values" => ["5"] } }),
      query(5, filters: { "sprint_id" => { "operator" => "=", "values" => ["99"] } }),
      query(6, filters: { "fixed_version_id" => { "operator" => "=", "values" => ["32"] } }),
      query(7, type: "AgileQuery"),
      query(8, filters: { "subproject_id" => { "operator" => "!*", "values" => [""] } })
    ]
    events = sync
    assert_equal %w[ignored ignored ignored ignored ignored ignored create], events.map { |event| event[:action] }
    assert_match(/status 12 of filter "status_id" is not mapped/, events[0][:reason])
    assert_match(/user 8 .* is anonymized/, events[1][:reason])
    assert_match(/names projects/, events[2][:reason])
    assert_match(/filter "agile_sprints" does not exist here/, events[3][:reason]) unless IssueQuery.new(project: @project).available_filters.key?("agile_sprints")
    assert_match(/value 32 of filter "fixed_version_id" has no correspondence/, events[4][:reason])
    assert_match(/AgileQuery needs a plugin/, events[5][:reason]) unless defined?(::AgileQuery)
  end

  def test_private_queries_go_to_their_owner_unless_anonymized
    @source.queries = [query(9, visibility: 0), query(10, visibility: 0, user: { "id" => 8, "name" => "Gone" })]
    events = sync
    assert_equal %w[create ignored], events.map { |event| event[:action] }
    assert_equal [2, Query::VISIBILITY_PRIVATE], [imported(9).user_id, imported(9).visibility]
    assert_match(/private owner is anonymized/, events.last[:reason])
  end

  # Mapped roles; without any, the roles that can edit the project.
  def test_role_queries_keep_mapped_roles_or_go_to_project_managers
    @source.queries = [query(11, visibility: 1, roles: [{ "id" => 41, "name" => "Dev" }]),
      query(12, visibility: 1, roles: [{ "id" => 42, "name" => "Unmapped" }])]
    sync
    assert_equal [2], imported(11).role_ids
    managers = @project.members.flat_map(&:roles).uniq.select { |role| role.allowed_to?(:edit_project) }.map(&:id).sort
    assert managers.any?
    assert_equal managers, imported(12).role_ids.sort
  end

  def test_time_entry_queries_translate_issue_fields
    @source.queries = [query(13, type: "TimeEntryQuery", filters: { "issue.tracker_id" => { "operator" => "=", "values" => ["21"] },
      "user_id" => { "operator" => "=", "values" => ["7"] } })]
    sync
    local = imported(13)
    assert_instance_of TimeEntryQuery, local
    assert_equal ["2"], local.filters.dig("issue.tracker_id", :values)
    assert_equal ["2"], local.filters.dig("user_id", :values)
  end

  def test_local_edit_is_a_conflict_unless_the_source_wins
    @source.queries = [query(14)]
    sync
    imported(14).update!(name: "Renamed locally")
    assert_raises(RedmineMirror::Error) { sync }
    RedmineMirror::Policy.with(source_wins: true) { sync }
    assert_equal "Query 14", imported(14).name
  end
end
