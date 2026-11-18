# frozen_string_literal: true
# File: redmine_mirror/test/unit/members_test.rb
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

class MirrorMembersTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :groups_users, :enabled_modules

  class Store
    def initialize; @rows = {}; end
    def find(key, id); @rows[[key, id]]; end
    def save(key, id, values); @rows[[key, id]] = values; end
  end

  def setup
    @project = Project.find(1)
    @store = Store.new
    @adapter = RedmineMirror::Adapters::Members.new
    # Source roles 41 and 42 are local Reporter (3) and Developer (2); 43 is not given.
    @mappings = { "user" => { "70" => "8", "71" => "2", "72" => "anonymous" }, "group" => { "80" => "10" },
      "role" => { "41" => "3", "42" => "2", "43" => "ignore" } }
  end

  def membership(id, principal, roles)
    { "id" => id, "project" => { "id" => 9 }, principal.keys.first => principal.values.first,
      "roles" => roles.map { |role_id, inherited| { "id" => role_id, "name" => "Role #{role_id}" }.merge(inherited ? { "inherited" => true } : {}) } }
  end

  def sync(record, apply: true)
    @adapter.synchronize(record, project_id: @project.id, mappings: @mappings, lookup: nil, store: @store, source: nil, apply: apply)
  end

  def test_new_member_with_own_roles_only_then_unchanged
    record = membership(1, { "user" => { "id" => 70 } }, [[41, false], [42, true]])
    assert_equal "create", sync(record, apply: false)[:action]
    refute @project.memberships.exists?(user_id: 8)
    sync(record)
    assert_equal [3], @project.memberships.find_by!(user_id: 8).role_ids
    assert_equal "unchanged", sync(record)[:action]
  end

  def test_existing_member_gains_missing_roles_and_keeps_its_own
    assert_equal [1], @project.memberships.find_by!(user_id: 2).role_ids
    assert_equal "update", sync(membership(2, { "user" => { "id" => 71 } }, [[42, false]]))[:action]
    assert_equal [1, 2], @project.memberships.find_by!(user_id: 2).role_ids.sort
  end

  def test_locked_user_and_group_are_added
    User.find(8).lock!
    sync(membership(3, { "user" => { "id" => 70 } }, [[41, false]]))
    assert @project.memberships.exists?(user_id: 8)
    sync(membership(4, { "group" => { "id" => 80 } }, [[42, false]]))
    assert_equal [2], @project.memberships.find_by!(user_id: 10).role_ids
  end

  def test_anonymized_user_and_ignored_roles_are_skipped
    assert_equal "ignored", sync(membership(5, { "user" => { "id" => 72 } }, [[41, false]]))[:action]
    assert_equal "ignored", sync(membership(6, { "user" => { "id" => 70 } }, [[43, false]]))[:action]
    refute @project.memberships.exists?(user_id: 8)
    assert_raises(RedmineMirror::Error) { sync(membership(7, { "user" => { "id" => 99 } }, [[41, false]])) }
  end

  def test_unmapped_roles_block_or_are_not_given_with_the_option
    @project.enable_module!(:mirror)
    setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 12)
    setting.selected_modules = %w[project_members]
    setting.api_key = "private-api-key"
    setting.save!
    record = membership(8, { "user" => { "id" => 70 } }, [[41, false], [99, false]])
    assert_raises(RedmineMirror::Error) { sync(record) }
    setting.update!(module_options: setting.module_options.merge("project_members" => { "unmapped" => "skip" }))
    sync(record)
    assert_equal [3], @project.memberships.find_by!(user_id: 8).role_ids
    assert_equal "ignored", sync(membership(9, { "user" => { "id" => 71 } }, [[99, false]]))[:action]
    assert_raises(RedmineMirror::Error) { @adapter.configuration_options({ "unmapped" => "maybe" }, @project) }
  end

  def test_role_removed_locally_is_a_conflict
    record = membership(1, { "user" => { "id" => 70 } }, [[41, false]])
    sync(record)
    member = @project.memberships.find_by!(user_id: 8)
    member.role_ids = [2]
    member.save!
    error = assert_raises(RedmineMirror::Error) { sync(record) }
    assert_match(/Local modification detected for project_members/, error.message)
  end

  def run_members(records, source_wins: false, apply: true, incremental: false, changes: [])
    @store = RedmineMirror::DatabaseStore.new("members-alias-test", project_id: @project.id)
    source = Object.new
    source.define_singleton_method(:get) do |path, _params = {}|
      if path == "projects/9/memberships.json"
        { "memberships" => records, "total_count" => records.size }
      elsif path.start_with?("memberships/")
        raise RedmineMirror::Error, "Redmine API returned HTTP 404"
      else
        {}
      end
    end
    previous_url = ENV["MIRROR_DESTINATION_URL"]
    ENV["MIRROR_DESTINATION_URL"] = "https://destination.example"
    RedmineMirror::Runner.new(source: source, destination: source, store: @store).run({
      "source_project_id" => 9, "destination_project_id" => @project.id,
      "destination_url" => ENV["MIRROR_DESTINATION_URL"], "modules" => ["project_members"],
      "mappings" => @mappings, "source_wins" => source_wins,
      "incremental" => incremental, "changes" => changes
    }, apply: apply)
  ensure
    ENV["MIRROR_DESTINATION_URL"] = previous_url
  end

  def aliased_members
    @mappings["user"]["73"] = "8"
    [membership(101, { "user" => { "id" => 70 } }, [[41, false]]),
      membership(102, { "user" => { "id" => 73 } }, [[42, false]])]
  end

  def test_aliased_members_share_one_destination_and_repeat_without_changes
    records = aliased_members
    run_members(records)
    member = @project.memberships.find_by!(user_id: 8)
    assert_equal [2, 3], member.role_ids.sort
    assert_equal [member.id, member.id], @store.mappings("project_members").sort.map(&:last)
    assert_equal ["unchanged", "unchanged"], run_members(records.reverse).map { |event| event[:action] }
    assert_equal 1, @project.memberships.where(user_id: 8).count
  end

  def test_source_wins_combines_roles_and_keeps_member_until_last_alias_is_deleted
    records = aliased_members
    run_members(records, source_wins: true)
    member = @project.memberships.find_by!(user_id: 8)
    assert_equal [2, 3], member.role_ids.sort
    assert_equal ["unchanged", "unchanged"], run_members(records.reverse, source_wins: true).map { |event| event[:action] }
    events = run_members([records.last], source_wins: true)
    assert_equal [2], member.reload.role_ids
    assert_equal [102], @store.mappings("project_members").map(&:first)
    assert events.any? { |event| event[:source_id] == 101 && event[:action] == "delete" }
    run_members([], source_wins: true)
    refute Member.exists?(member.id)
    assert_empty @store.mappings("project_members")
  end

  def test_preview_of_aliases_does_not_write_and_cross_project_roles_are_excluded
    records = aliased_members
    foreign = membership(103, { "user" => { "id" => 70 } }, [[42, false]])
    foreign["project"]["id"] = 99
    run_members([records.first, foreign], apply: false)
    refute @project.memberships.exists?(user_id: 8)
    assert_empty @store.mappings("project_members")
    run_members([records.first, foreign])
    assert_equal [3], @project.memberships.find_by!(user_id: 8).role_ids
  end

  def test_aliases_preserve_local_roles_and_detect_local_removal
    records = aliased_members
    run_members(records)
    member = @project.memberships.find_by!(user_id: 8)
    member.update!(role_ids: [1, 2, 3])
    run_members(records)
    assert_equal [1, 2, 3], member.reload.role_ids.sort
    member.update!(role_ids: [1, 2])
    assert_raises(RedmineMirror::Error) { run_members(records) }
  end

  def test_groups_can_share_a_local_member_and_inherited_roles_are_not_copied
    @mappings["group"]["81"] = "10"
    records = [membership(101, { "group" => { "id" => 80 } }, [[41, false], [42, true]]),
      membership(102, { "group" => { "id" => 81 } }, [[43, false]])]
    run_members(records)
    member = @project.memberships.find_by!(user_id: 10)
    assert_equal [3], member.role_ids
    assert_equal [101], @store.mappings("project_members").map(&:first)
  end

  def test_incremental_runs_keep_the_roles_of_unchanged_aliases
    records = aliased_members
    run_members(records, source_wins: true)
    @mappings["role"]["44"] = "1"
    records.first["roles"] = [{ "id" => 44 }]
    run_members(records, source_wins: true, incremental: true,
      changes: [{ "module_key" => "project_members", "source_id" => 101, "action" => "upsert" }])
    assert_equal [1, 2], @project.memberships.find_by!(user_id: 8).role_ids.sort
  end

  def test_other_modules_still_reject_a_shared_destination
    store = RedmineMirror::DatabaseStore.new("members-alias-test", project_id: @project.id)
    values = { "destination_id" => 1, "source_fingerprint" => "source", "destination_fingerprint" => "destination" }
    store.save("issue_tracking", 101, values)
    assert_raises(ActiveRecord::RecordNotUnique) do
      MirrorMapping.transaction(requires_new: true) { store.save("issue_tracking", 102, values) }
    end
  end

  def test_members_managers_choose_among_all_accounts
    @project.enable_module!(:mirror)
    setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 12)
    setting.selected_modules = %w[issue_tracking]
    setting.api_key = "private-api-key"
    setting.save!
    table = RedmineMirror::MappingTable.new("user")
    User.current = User.find(1)
    refute_includes table.local_records(@project).map(&:id), 8
    setting.update!(selected_modules: %w[project_members])
    assert_includes table.local_records(@project.reload).map(&:id), 8
    Role.find(2).remove_permission!(:manage_members)
    User.current = User.find(3) # Developer, now without Manage members
    refute_includes table.local_records(@project).map(&:id), 8
  ensure
    User.current = nil
  end
end
