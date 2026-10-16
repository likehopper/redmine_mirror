# frozen_string_literal: true
# File: redmine_mirror/test/unit/issue_state_test.rb
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

class MirrorIssueStateTest < ActiveSupport::TestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :issues, :issue_statuses, :trackers, :enumerations, :enabled_modules, :watchers

  class Store
    attr_reader :rows
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
    def resolve_issue(id); @external && @external[id]; end
    attr_writer :external
  end

  def setup
    @issue = Issue.find(2)
    @parent = Issue.find(1)
    @issue.parent_issue_id = nil
    @issue.save!
    @issue.watcher_users = []
    @store = Store.new
    @lookup = ->(key, id) { key == "issue_tracking" && { 100 => @issue.id, 101 => @parent.id }[id] }
    @record = { "id" => 100, "project" => { "id" => 99 }, "parent" => { "id" => 101 }, "watchers" => [{ "id" => 7, "name" => "External watcher" }] }
  end

  def run_adapter(adapter, apply: true, mappings: { "user" => { "7" => "1" } })
    adapter.synchronize(@record, project_id: @issue.project_id, mappings: mappings,
      lookup: @lookup, store: @store, source: nil, apply: apply)
  end

  def test_hierarchy_preview_apply_repeat_and_conflict
    adapter = RedmineMirror::Adapters::Hierarchy.new
    before = @issue.reload.updated_on
    assert_equal "update", run_adapter(adapter, apply: false)[:action]
    assert_nil @issue.reload.parent_id
    assert_empty @store.rows
    run_adapter(adapter)
    assert_equal @parent.id, @issue.reload.parent_id
    assert_equal before, @issue.updated_on
    assert_equal "unchanged", run_adapter(adapter)[:action]
    @issue.parent_issue_id = nil
    @issue.save!
    assert_raises(RedmineMirror::Error) { run_adapter(adapter) }
  end

  def test_unmapped_parent_is_deferred_then_resolved
    adapter = RedmineMirror::Adapters::Hierarchy.new
    @record["parent"]["id"] = 999
    assert_equal "ignored", run_adapter(adapter)[:action]
    assert_nil @issue.reload.parent_id
    assert_empty @store.rows
    @store.external = { 999 => @parent.id }
    run_adapter(adapter)
    assert_equal @parent.id, @issue.reload.parent_id
  end

  def test_watchers_preview_anonymization_idempotence_and_conflict
    adapter = RedmineMirror::Adapters::Watchers.new
    assert_equal [{ "id" => 7, "name" => "External watcher" }], adapter.referenced_users(@record)
    run_adapter(adapter, apply: false)
    assert_empty @issue.reload.watcher_users
    run_adapter(adapter, mappings: { "user" => { "7" => "anonymous" } })
    assert_empty @issue.reload.watcher_users
    run_adapter(adapter)
    assert_equal [1], @issue.reload.watcher_users.pluck(:id)
    assert_equal "unchanged", run_adapter(adapter)[:action]
    @issue.watcher_users = []
    assert_raises(RedmineMirror::Error) { run_adapter(adapter) }
  end

  def test_missing_source_permission_and_mapping_are_errors
    adapter = RedmineMirror::Adapters::Watchers.new
    assert_raises(RedmineMirror::Error) { run_adapter(adapter, mappings: {}) }
    @record.delete("watchers")
    assert_raises(RedmineMirror::Error) { run_adapter(adapter) }
  end

  def test_watcher_without_visibility_is_rejected
    @issue.update_columns(is_private: true)
    adapter = RedmineMirror::Adapters::Watchers.new
    outsider = User.active.where(admin: false).detect { |user| !@issue.visible?(user) }
    assert outsider
    assert_raises(RedmineMirror::Error) { run_adapter(adapter, mappings: { "user" => { "7" => outsider.id.to_s } }) }
    assert_empty @issue.reload.watcher_users
  end
  def test_cycle_is_rejected_in_preview
    @record["parent"]["id"] = 100
    assert_raises(RedmineMirror::Error) { run_adapter(RedmineMirror::Adapters::Hierarchy.new, apply: false) }
    assert_nil @issue.reload.parent_id
  end

  def test_cross_project_parent_requires_native_permission
    outside = Issue.where.not(project_id: @issue.project_id).first!
    @record["parent"]["id"] = 999
    @store.external = { 999 => outside.id }
    with_settings cross_project_subtasks: "" do
      assert_raises(RedmineMirror::Error) { run_adapter(RedmineMirror::Adapters::Hierarchy.new, apply: false) }
      assert_nil @issue.reload.parent_id
    end
  end

  def test_local_subscriptions_and_remote_removals_are_preserved
    @issue.watcher_users = [User.find(1)]
    @record["watchers"] = []
    adapter = RedmineMirror::Adapters::Watchers.new
    assert_equal "unchanged", run_adapter(adapter)[:action]
    assert_equal [1], @issue.reload.watcher_users.pluck(:id)
    @record["watchers"] = [{ "id" => 7 }]
    run_adapter(adapter)
    @record["watchers"] = []
    run_adapter(adapter)
    assert_equal [1], @issue.reload.watcher_users.pluck(:id)
  end

  def test_parent_diagnostic_is_written_for_apply_preflight_only_and_cleared_on_success
    store = RedmineMirror::DatabaseStore.new("parent-test", project_id: @issue.project_id)
    adapter = RedmineMirror::Adapters::Hierarchy.new
    @record["parent"]["id"] = 100
    args = { project_id: @issue.project_id, mappings: {}, lookup: @lookup, store: store, source: nil, apply: false }
    assert_raises(RedmineMirror::Error) { adapter.synchronize(@record, **args) }
    assert_not MirrorPendingParent.exists?(connection_key: "parent-test")
    assert_raises(RedmineMirror::Error) { adapter.synchronize(@record, **args, track_blocks: true) }
    row = MirrorPendingParent.find_by!(connection_key: "parent-test")
    assert_equal "blocked", row.status
    assert_equal @issue.id, row.local_issue_id
    assert_equal 100, row.remote_parent_id
    @record["parent"]["id"] = 101
    adapter.synchronize(@record, **args.merge(apply: true))
    assert_not MirrorPendingParent.exists?(connection_key: "parent-test")
    assert_equal @parent.id, @issue.reload.parent_id
  end

end
