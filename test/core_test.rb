# frozen_string_literal: true
# File: redmine_mirror/test/core_test.rb
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

require "minitest/autorun"
require_relative "../lib/redmine_mirror"

class MirrorCoreTest < Minitest::Test
  class Store
    attr_reader :rows
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
    def resolve_issue(_id); nil; end
  end

  class Api
    attr_reader :writes, :records
    def initialize(records = {})
      @records = records
      @writes = []
    end
    def each_record(collection, _params); @records.fetch(collection, []).each; end
    def get(path, _params = {})
      return { "project" => { "id" => 1 } } if path.start_with?("projects/")
      collection, id = path.delete_suffix(".json").split("/")
      entity = collection == "issues" ? "issue" : "time_entry"
      { entity => @records.fetch(collection).find { |record| record["id"] == id.to_i } }
    end
    def create(path, body)
      collection = path.delete_suffix(".json")
      entity, attributes = body.first
      record = attributes.dup
      record["id"] = 100 + @writes.size
      record["project"] = { "id" => record.delete("project_id") }
      %w[tracker status priority assigned_to author activity user issue].each do |kind|
        id = record.delete("#{kind}_id")
        record[kind] = { "id" => id } if id
      end
      (@records[collection] ||= []) << record
      @writes << [:create, path, body]
      { entity => record }
    end
    def update(path, body)
      record = get(path).values.first
      entity, attributes = body.first
      attributes.each do |key, value|
        if key.end_with?("_id")
          record[key.delete_suffix("_id")] = value && { "id" => value }
        else
          record[key] = value
        end
      end
      @writes << [:update, path, body]
      {}
    end
  end

  def setup
    @issue = { "id" => 3, "project" => { "id" => 1 }, "subject" => "Example", "tracker" => { "id" => 1 },
      "status" => { "id" => 1 }, "priority" => { "id" => 1 } }
    @source = Api.new("issues" => [@issue], "time_entries" => [
      { "id" => 8, "project" => { "id" => 1 }, "issue" => { "id" => 3 }, "hours" => 2.0,
        "spent_on" => "2026-10-07", "activity" => { "id" => 1 }, "user" => { "id" => 1 } }])
    @destination = Api.new
    @store = Store.new
    @config = { "source_project_id" => 1, "destination_project_id" => 2, "modules" => ["time_tracking"],
      "mappings" => %w[tracker status priority activity user].to_h { |kind| [kind, { "1" => 10 }] } }
    @runner = RedmineMirror::Runner.new(source: @source, destination: @destination, store: @store)
  end

  # Mirror mode doubles: the API answers 404 for a missing object, the store lists and
  # deletes correspondences, and the issues adapter records local deletions.
  class MirrorApi < Api
    attr_accessor :hidden
    def each_record(collection, params); super.reject { |record| Array(hidden).include?(record["id"]) }.each; end
    def get(path, params = {})
      result = super
      raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}" if result.values.first.nil?
      result
    end
  end

  class MirrorStore < Store
    def mappings(key); rows.filter_map { |(module_key, id), row| [id, row.fetch("destination_id")] if module_key == key }; end
    def delete(key, id); rows.delete([key, id]); end
  end

  class MirrorIssues < RedmineMirror::Adapters::Issues
    def deleted; @deleted ||= []; end
    def delete_local(destination_id, _project_id); deleted << destination_id; end
  end

  def mirror_runner(count)
    issues = (1..count).map { |id| @issue.merge("id" => id, "subject" => "Issue #{id}") }
    @source = MirrorApi.new("issues" => issues)
    @destination = MirrorApi.new
    @store = MirrorStore.new
    registry = RedmineMirror::Registry.new
    registry.register(RedmineMirror::Adapters::Users.new)
    registry.register(@issues = MirrorIssues.new)
    @config = @config.merge("modules" => ["issue_tracking"], "on_error" => "collect")
    RedmineMirror::Runner.new(source: @source, destination: @destination, store: @store, registry: registry)
  end

  def test_source_wins_overwrites_local_changes_and_recreates_deletions
    runner = mirror_runner(1)
    runner.run(@config, apply: true)
    @destination.records["issues"].first["subject"] = "Local edit"
    assert_match(/Local modification/, runner.run(@config, apply: true).first[:reason])
    event = runner.run(@config.merge("source_wins" => true), apply: true).first
    assert_equal ["update", ["local_overwritten"]], [event[:action], event[:flags]]
    assert_equal "Issue 1", @destination.records["issues"].first["subject"]
    @destination.records["issues"].clear
    event = runner.run(@config.merge("source_wins" => true), apply: true).first
    assert_equal ["create", ["recreated"]], [event[:action], event[:flags]]
    assert_equal 1, @destination.records["issues"].size
  end

  def test_source_deletions_are_verified_limited_and_confirmed
    runner = mirror_runner(30)
    config = @config.merge("source_wins" => true)
    runner.run(config, apply: true)
    # Missing from the list but still on the source: kept.
    @source.hidden = [1]
    assert_equal ["ignored"], runner.run(config, apply: true).reject { |event| event[:action] == "unchanged" }.map { |event| event[:action] }
    @source.hidden = []
    # Up to 10% of the module (at least 2) is deleted without confirmation.
    @source.records["issues"].reject! { |issue| [2, 3].include?(issue["id"]) }
    events = runner.run(config, apply: true).select { |event| event[:action] == "delete" }
    assert_equal [2, 3], events.map { |event| event[:source_id] }.sort
    assert_equal 2, @issues.deleted.size
    assert_nil @store.find("issue_tracking", 2)
    # Beyond the limit, nothing is deleted until a run confirms it.
    @source.records["issues"].reject! { |issue| issue["id"].between?(4, 10) }
    blocked = runner.run(config, apply: true).select { |event| event[:reason].to_s.start_with?("Deletion awaits confirmation") }
    assert_equal 7, blocked.size
    assert_equal 2, @issues.deleted.size
    assert_equal 7, runner.run(config.merge("confirm_deletions" => true), apply: true).count { |event| event[:action] == "delete" }
    assert_equal 9, @issues.deleted.size
    # The preview lists deletions without deleting.
    @source.records["issues"].reject! { |issue| issue["id"] == 11 }
    assert_equal [11], runner.run(config).select { |event| event[:action] == "delete" }.map { |event| event[:source_id] }
    assert_equal 9, @issues.deleted.size
  end

  def test_preview_resolves_dependencies_without_writes
    result = @runner.run(@config)
    assert_equal %w[issue_tracking time_tracking], result.map { |item| item[:module] }
    assert_equal %w[create create], result.map { |item| item[:action] }
    assert_empty @destination.writes
    assert_empty @store.rows
  end

  def test_apply_is_repeatable_and_remaps_time_entry_issue
    @runner.run(@config, apply: true)
    assert_equal 100, @destination.records["time_entries"].first["issue"]["id"]
    events = @runner.run(@config)
    assert_equal [100, 101], events.map { |event| event[:destination_id] }
    assert_equal %w[unchanged unchanged], @runner.run(@config, apply: true).map { |item| item[:action] }
    assert_equal 2, @destination.writes.length
    @issue["subject"] = "Updated source"
    assert_equal "update", @runner.run(@config, apply: true).first[:action]
    assert_equal "Updated source", @destination.records["issues"].first["subject"]
  end

  def test_ignored_tracker_leaves_its_issues_and_their_records_out_without_errors
    @source.records["issues"] << @issue.merge("id" => 4, "tracker" => { "id" => 7 })
    @source.records["time_entries"] << @source.records["time_entries"].first.merge("id" => 9, "issue" => { "id" => 4 })
    @config["mappings"]["tracker"]["7"] = "ignore"
    events = @runner.run(@config, apply: true)
    assert_equal [[3, "create"], [4, "ignored"], [8, "create"], [9, "ignored"]], events.map { |event| [event[:source_id], event[:action]] }
    assert_equal "Tracker ignored by the mapping", events[1][:reason]
    assert_equal "Issue #4 not imported: its tracker is ignored by the mapping", events[3][:reason]
    assert_equal 2, @destination.writes.length
    # Without the "ignore" choice, the unmapped tracker is still an error.
    @config["mappings"]["tracker"].delete("7")
    assert_raises(RedmineMirror::Error) { @runner.run(@config) }
    assert RedmineMirror::MappingTable.new("tracker").ignore_allowed?
    refute RedmineMirror::MappingTable.new("priority").ignore_allowed?
    refute RedmineMirror::MappingTable.new("user").ignore_allowed?
  end

  # An ignored status leaves its issues out like a tracker; an ignored activity, its time entries.
  def test_ignored_status_and_activity_leave_their_records_out_without_errors
    @source.records["issues"] << @issue.merge("id" => 4, "status" => { "id" => 7 })
    @source.records["time_entries"] << @source.records["time_entries"].first.merge("id" => 9, "issue" => { "id" => 4 })
    @source.records["time_entries"] << @source.records["time_entries"].first.merge("id" => 10, "activity" => { "id" => 7 })
    @config["mappings"]["status"]["7"] = "ignore"
    @config["mappings"]["activity"]["7"] = "ignore"
    events = @runner.run(@config, apply: true)
    assert_equal [[3, "create"], [4, "ignored"], [8, "create"], [9, "ignored"], [10, "ignored"]], events.map { |event| [event[:source_id], event[:action]] }
    assert_equal ["Status ignored by the mapping", "Issue #4 not imported: its status is ignored by the mapping", "Activity ignored by the mapping"],
      events.values_at(1, 3, 4).map { |event| event[:reason] }
    assert_equal 2, @destination.writes.length
    %w[status activity document_category].each { |kind| assert RedmineMirror::MappingTable.new(kind).ignore_allowed? }
    assert_equal "document_category", RedmineMirror::Adapters::Documents.new.ignored_reference({ "category" => { "id" => 5 } }, { "document_category" => { "5" => "ignore" } })
  end

  def test_relations_and_parents_of_an_ignored_issue_are_ignored
    ignored = { 4 => true }
    relations = RedmineMirror::Adapters::Relations.new
    assert relations.source_issue_ids({ "issue_id" => 3, "issue_to_id" => 4 }).any? { |id| ignored[id] }
    hierarchy = RedmineMirror::Adapters::Hierarchy.new
    assert_equal [3, 4], hierarchy.source_issue_ids(@issue.merge("parent" => { "id" => 4 }))
    assert_equal [3], RedmineMirror::Adapters::Journals.new.source_issue_ids({ "issue_id" => 3 })
    assert_equal [], RedmineMirror::Adapters::TimeEntries.new.source_issue_ids({ "id" => 1 })
  end

  def test_local_edit_is_a_conflict_even_if_source_unchanged
    @runner.run(@config, apply: true)
    @destination.records["issues"].first["subject"] = "Local edit"
    assert_raises(RedmineMirror::Error) { @runner.run(@config, apply: true) }
    assert_equal 2, @destination.writes.length
  end

  def test_private_issue_and_author_mapping
    @issue["is_private"] = true
    @issue["author"] = { "id" => 1 }
    @runner.run(@config, apply: true)
    imported = @destination.records["issues"].first
    assert_equal true, imported["is_private"]
    assert_equal 10, imported["author"]["id"]
    imported["is_private"] = false
    assert_raises(RedmineMirror::Error) { @runner.run(@config, apply: true) }
  end

  def test_issue_dates_require_local_destination_before_writing
    @issue["created_on"] = "2025-12-01T09:00:00Z"
    error = assert_raises(RedmineMirror::Error) { @runner.run(@config, apply: true) }
    assert_includes error.message, "local destination"
    assert_empty @destination.writes
  end

  def test_categories_and_versions_are_ordered_before_issues
    keys = RedmineMirror::REGISTRY.resolve(%w[issue_relations project_versions issue_categories]).map(&:key)
    assert_operator keys.index("project_versions"), :<, keys.index("issue_tracking")
    assert_operator keys.index("issue_categories"), :<, keys.index("issue_tracking")
  end

  def test_issue_reference_correspondences_are_required
    @issue["category"] = { "id" => 20 }
    assert_raises(RedmineMirror::Error) { @runner.run(@config) }
    assert_empty @destination.writes
    payload = RedmineMirror::Adapters::Issues.new.payload(@issue, 2, @config.fetch("mappings"), ->(key, id) { key == "issue_categories" && id == 20 ? 120 : nil })
    assert_equal 120, payload["category_id"]
  end

  def test_relations_reject_invalid_missing_target_policy
    assert_raises(RedmineMirror::Error) do
      RedmineMirror::Adapters::Relations.new.configuration_options({ "missing_target" => "unsafe" }, nil)
    end
  end

  def test_relations_are_deduplicated_from_both_endpoints
    relation = { "id" => 42, "issue_id" => 3, "issue_to_id" => 4, "relation_type" => "relates" }
    @issue["relations"] = [relation]
    @source.records["issues"] << @issue.merge("id" => 4)
    records = RedmineMirror::Adapters::Relations.new.records(@source, 1).to_a
    assert_equal [42], records.map { |record| record["id"] }
    assert_equal 3, records.first["issue_id"]
  end

  def test_missing_relation_endpoint_is_logged_without_writes
    relation = { "id" => 42, "issue_id" => 3, "issue_to_id" => 99, "relation_type" => "relates", "owner_issue_id" => 3 }
    event = RedmineMirror::Adapters::Relations.new.synchronize(relation, project_id: 2,
      mappings: {}, lookup: ->(_key, id) { id == 3 ? "planned:3" : nil }, store: @store, source: @source, apply: false)
    assert_equal "ignored", event[:action]
    assert_equal "Remote endpoint not synchronized", event[:reason]
    assert_empty @store.rows
  end

  def test_invalid_issue_date_fails_before_writing
    @issue["created_on"] = "invalid"
    error = assert_raises(RedmineMirror::Error) { @runner.run(@config, apply: true) }
    assert_includes error.message, "Invalid source issue date"
    assert_empty @destination.writes
  end

  def test_missing_author_mapping_fails_before_writing
    @issue["author"] = { "id" => 99 }
    assert_raises(RedmineMirror::Error) { @runner.run(@config, apply: true) }
    assert_empty @destination.writes
  end

  def test_missing_mapping_fails_closed
    @config["mappings"].delete("tracker")
    assert_raises(RedmineMirror::Error) { @runner.run(@config) }
    assert_empty @destination.writes
  end

  def test_descendant_records_are_excluded
    @issue["project"]["id"] = 9
    @config["modules"] = ["issue_tracking"]
    assert_empty @runner.run(@config, apply: true)
    assert_empty @store.rows
  end

  def test_moved_destination_is_rejected
    @runner.run(@config, apply: true)
    @destination.records["issues"].first["project"]["id"] = 99
    assert_raises(RedmineMirror::Error) { @runner.run(@config) }
  end

  def test_registry_rejects_unknown_and_duplicate_modules
    assert_raises(RedmineMirror::Error) { RedmineMirror::REGISTRY.resolve(["unknown_module"]) }
    assert_raises(RedmineMirror::Error) { RedmineMirror::REGISTRY.register(RedmineMirror::Adapters::Issues.new) }
  end

  class ExternalAdapter < RedmineMirror::Adapters::Base
    def initialize(key, phase: :default, api_version: RedmineMirror::ADAPTER_API_VERSION)
      @key, @phase, @api_version = key, phase, api_version
    end
    attr_reader :key, :phase, :api_version
    def dependencies; ["users"]; end
  end

  def test_external_adapters_follow_the_registration_contract
    registry = RedmineMirror::Registry.new
    assert_raises(RedmineMirror::Error) { registry.register(ExternalAdapter.new("Bad-Key")) }
    assert_raises(RedmineMirror::Error) { registry.register(ExternalAdapter.new("sla_trackers", api_version: RedmineMirror::ADAPTER_API_VERSION + 1)) }
    assert_raises(RedmineMirror::Error) { registry.register(ExternalAdapter.new("sla_trackers", phase: :late)) }
    assert_empty registry.keys
    assert_raises(RedmineMirror::Error) { RedmineMirror.register_adapter(ExternalAdapter.new("users")) }
  end

  def test_external_adapters_are_ordered_by_declared_phase
    registry = RedmineMirror::Registry.new
    registry.register(RedmineMirror::Adapters::Users.new)
    registry.register(RedmineMirror::Adapters::Issues.new)
    registry.register(ExternalAdapter.new("external_history", phase: :history))
    registry.register(ExternalAdapter.new("external_references", phase: :references))
    keys = registry.resolve(%w[external_history issue_tracking external_references]).map(&:key)
    assert_equal %w[users external_references issue_tracking external_history], keys
    assert registry["external_history"].available?
    assert_nil registry["missing"]
  end

  def test_read_only_source_key_lists_categories_from_issues
    client = Object.new
    def client.get(path, _params = {})
      raise RedmineMirror::Error, "Redmine API returned HTTP 403 for GET #{path}" if path.include?("issue_categories")
      raise RedmineMirror::Error, "Redmine API returned HTTP 500 for GET #{path}"
    end
    def client.each_record(_collection, _params)
      [{ "id" => 1, "category" => { "id" => 4, "name" => "Backend" } }, { "id" => 2 },
       { "id" => 3, "category" => { "id" => 4, "name" => "Backend" } }].each
    end
    records = RedmineMirror::Adapters::Categories.new.records(client, 7)
    assert_equal [{ "project" => { "id" => 7 }, "id" => 4, "name" => "Backend" }], records
    # Categories of other projects used by the issues are added to the project's own.
    def client.get(path, _params = {})
      { "issue_categories" => [{ "id" => 9, "name" => "Own", "project" => { "id" => 7 } }] }
    end
    assert_equal [9, 4], RedmineMirror::Adapters::Categories.new.records(client, 7).map { |category| category.fetch("id") }
    def client.get(path, _params = {}) = raise(RedmineMirror::Error, "Redmine API returned HTTP 500 for GET #{path}")
    assert_raises(RedmineMirror::Error) { RedmineMirror::Adapters::Categories.new.records(client, 7) }
  end

  def test_collect_mode_reports_every_failing_object_and_continues
    @issue["status"] = { "id" => 999 }
    assert_raises(RedmineMirror::Error) { @runner.run(@config) }
    events = @runner.run(@config.merge("on_error" => "collect"))
    failed = events.select { |event| event[:action] == "error" }
    assert_equal %w[issue_tracking time_tracking], failed.map { |event| event[:module] }.uniq.sort
    assert(failed.all? { |event| !event[:reason].to_s.empty? })
    assert_empty @destination.writes
  end

  def test_events_carry_the_special_cases_of_their_texts
    @issue["description"] = "h2. Notes\n\nSee #12, https://source.example/issues/3 and !shot.png!"
    @config["text_format"] = { "source" => "textile", "target" => "textile", "source_url" => "https://source.example" }
    events = @runner.run(@config)
    issue = events.find { |event| event[:module] == "issue_tracking" }
    assert_equal %w[issue_references source_links images issue_references_unresolved], issue[:flags]
    refute events.find { |event| event[:module] == "time_tracking" }.key?(:flags)
  end

  def test_issue_references_point_to_destination_issues
    settings = { "source" => "textile", "target" => "textile", "source_url" => "https://old.example",
      "destination_url" => "https://new.example" }
    RedmineMirror::TextFormat.with(settings) do
      RedmineMirror::TextFormat.lookup = ->(key, id) { key == "issue_tracking" && { 10 => 501, 11 => "planned:11" }[id] }
      RedmineMirror::TextFormat.reset_flags
      text = "See #10, ##10, #11 and #99; https://old.example/issues/10 and @#10@.\n\n<pre>#10</pre>"
      result = RedmineMirror::TextFormat.convert(text)
      assert_equal "See #501, ##501, #11 and \"#99\":https://old.example/issues/99; https://new.example/issues/501 and @#10@.\n\n<pre>#10</pre>", result
      assert_includes RedmineMirror::TextFormat.flags, "issue_references_unresolved"
      assert_includes RedmineMirror::TextFormat.flags, "issue_references_rewritten"
    end
  end

  # Issue 3 cites issue 4, imported after it: one applying run rewrites the reference.
  def test_references_to_issues_imported_later_converge_in_one_run
    @issue["description"] = "Depends on #4"
    @source.records["issues"] << { "id" => 4, "project" => { "id" => 1 }, "subject" => "Later", "tracker" => { "id" => 1 },
      "status" => { "id" => 1 }, "priority" => { "id" => 1 } }
    @config["text_format"] = { "source" => "textile", "target" => "textile", "source_url" => "https://old.example" }
    @runner.run(@config, apply: true)
    later = @store.find("issue_tracking", 4).fetch("destination_id")
    first = @destination.records["issues"].find { |record| record["subject"] == "Example" }
    assert_equal "Depends on ##{later}", first["description"]
    assert(@runner.run(@config, apply: true).all? { |event| event[:action] == "unchanged" })
  end

  def test_text_format_detection
    detect = ->(text) { RedmineMirror::TextFormat.detect(text) }
    assert_equal "textile", detect.call("h2. Notes\n\n\"A link\":https://www.redmine.org and !shot.png!")
    assert_equal "markdown", detect.call("## Notes\n\n**Bold** and `code` with [a link](https://x.org)")
    assert_equal "html", detect.call("<p>New <strong>HTML</strong> note</p>")
    assert_equal "textile", detect.call("p(. Indented paragraph")
    # Textile headings decide over backticks, "## " lines, links and pipe tables.
    mixed = "h1. Introduction\n\nTable `paysbdv_v2`.\n\n## first\n## second\n\n[doc](https://x.org)\n\n| a | b |\n|---|---|\n"
    assert_equal "textile", detect.call(mixed)
    # Except in Markdown that quotes Textile in a fenced block.
    assert_equal "markdown", detect.call("## Title\n\n```\nh1. Quoted Textile\n```\n")
    assert_nil detect.call("Just a sentence with *emphasis*.")
    assert_nil detect.call("  ")
  end

  def test_history_reports_the_statuses_trackers_and_priorities_it_uses
    journal = { "details" => [
      { "property" => "attr", "name" => "status_id", "old_value" => "1", "new_value" => "5" },
      { "property" => "attr", "name" => "priority_id", "old_value" => nil, "new_value" => "4" },
      { "property" => "attr", "name" => "subject", "old_value" => "a", "new_value" => "b" },
      { "property" => "cf", "name" => "status_id", "old_value" => "9", "new_value" => "9" }] }
    used = RedmineMirror::Adapters::Journals.new.used_references(journal)
    assert_equal({ "status" => %w[1 5], "priority" => %w[4] }, used)
  end

  def test_client_rejects_insecure_or_embedded_credentials
    %w[http://redmine.example https://user:secret@redmine.example https://redmine.example?secret=x].each do |url|
      assert_raises(RedmineMirror::Error) { RedmineMirror::Client.new(url: url, api_key: "key") }
    end
  end

  def test_anonymous_issue_is_unassigned_and_time_needs_fallback
    @config["mappings"]["user"]["1"] = "anonymous"
    assert_raises(RedmineMirror::Error) { @runner.run(@config) }
    assert_empty @destination.writes
    @config["module_options"] = { "users" => { "anonymous_user_id" => 50 } }
    @runner.run(@config, apply: true)
    assert_nil @destination.records["issues"].first["assigned_to"]
    assert_equal 50, @destination.records["time_entries"].first["user"]["id"]
  end


  def test_module_catalog_includes_unused_native_references_and_observed_users
    client = Object.new
    def client.get(path, _params = {})
      case path
      when "projects/1.json" then { "project" => { "id" => 1, "trackers" => [{ "id" => 77, "name" => "Unused tracker" }] } }
      when "issue_statuses.json" then { "issue_statuses" => [{ "id" => 80, "name" => "Unused status" }] }
      when "enumerations/issue_priorities.json" then { "issue_priorities" => [] }
      else raise "Unexpected path #{path}"
      end
    end
    record = @issue.merge("assigned_to" => { "id" => 8, "name" => "Remote user" })
    client.define_singleton_method(:each_record) { |_collection, _params| [record].each }
    catalog = RedmineMirror::SourceCatalog.new(client: client, project_id: 1,
      adapters: RedmineMirror::REGISTRY.resolve(["issue_tracking"])).fetch
    assert_equal "Unused tracker", catalog.dig("tracker", "77")
    assert_equal "Unused status", catalog.dig("status", "80")
    assert_equal "Remote user", catalog.dig("user", "8")
    assert catalog.dig("tracker", "1")
  end

  def test_invalid_url_is_reported_as_a_mirror_error
    assert_raises(RedmineMirror::Error) { RedmineMirror::Client.new(url: "https://invalid host", api_key: "key") }
  end

  def test_users_adapter_owns_identity_mapping_and_dependencies
    adapters = RedmineMirror::REGISTRY.resolve(["time_tracking"])
    assert_equal %w[users issue_tracking time_tracking], adapters.map(&:key)
    users = adapters.first
    assert_equal ["user"], users.mapping_tables.map(&:key)
    assert_empty adapters[1].mapping_tables.select { |table| table.key == "user" }
    assert_empty adapters[2].mapping_tables.select { |table| table.key == "user" }
    assert_equal 10, users.resolve(@config["mappings"], 1)
    assert_raises(RedmineMirror::Error) { users.resolve(@config["mappings"], 99) }
    @config["mappings"]["user"]["1"] = "anonymous"
    assert_nil users.resolve(@config["mappings"], 1)
    assert_raises(RedmineMirror::Error) { users.resolve(@config["mappings"], 1, required: true) }
    assert_equal 50, users.resolve(@config["mappings"], 1, required: true, options: { "anonymous_user_id" => 50 })
  end

  def test_legacy_time_options_still_supply_anonymous_fallback
    @config["mappings"]["user"]["1"] = "anonymous"
    @config["module_options"] = { "time_tracking" => { "anonymous_user_id" => 50 } }
    @runner.run(@config, apply: true)
    assert_equal 50, @destination.records["time_entries"].first["user"]["id"]
  end

  def test_users_options_override_legacy_time_options
    @config["mappings"]["user"]["1"] = "anonymous"
    @config["module_options"] = { "time_tracking" => { "anonymous_user_id" => 50 }, "users" => { "anonymous_user_id" => 60 } }
    @runner.run(@config, apply: true)
    assert_equal 60, @destination.records["time_entries"].first["user"]["id"]
  end

  # YAML keeps the last of two identical keys: a new key must never replace an older one.
  def test_locale_keys_are_unique_and_shared_by_both_languages
    keys = %w[en fr].to_h do |lang|
      lines = File.readlines(File.expand_path("../config/locales/#{lang}.yml", __dir__)).grep(/\A  [a-z0-9_]+:/)
      names = lines.map { |line| line[/\A  ([a-z0-9_]+):/, 1] }
      assert_empty names.tally.select { |_, count| count > 1 }.keys, "Duplicate #{lang} keys"
      [lang, names.sort]
    end
    assert_equal keys.fetch("en"), keys.fetch("fr")
  end
end
