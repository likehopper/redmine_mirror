# frozen_string_literal: true
# File: redmine_mirror/test/integration/mirror_module_overview_test.rb
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
# The overview at the top of the module tabs: mapping state, source figures against the
# objects linked in the project, the last run and the modules relied on.

require_relative "../test_helper"

class MirrorModuleOverviewTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :trackers,
    :projects_trackers, :issue_statuses, :enumerations, :workflows, :wikis, :wiki_pages, :wiki_contents

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    Role.find(1).add_permission!(:manage_mirror)
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 12)
    @setting.selected_modules = %w[wiki]
    @setting.api_key = "private-api-key"
    @setting.source_catalog = { "user" => { "5" => "Remote author" }, "user_used" => ["5"],
      "module_statistics" => { "wiki" => { "records" => 3 }, "users" => { "records" => 0 } }, "read_at" => "2026-10-22T08:00:00Z" }
    @setting.catalog_status = "ready"
    @setting.save!
    log_user("jsmith", "jsmith")
  end

  def wiki_tab
    get "/projects/ecookbook/settings/mirror", params: { mirror_tab: "wiki" }
    assert_response :success
  end

  def test_tab_without_references_says_there_is_nothing_to_map
    wiki_tab
    assert_select "#mirror-mapping-state", text: /Nothing to map in this tab/
    # The authors' correspondences are in Users, still to map.
    assert_select "#mirror-module-dependencies a[href*='mirror_tab=users']", text: "Users"
    assert_select "#mirror-module-dependencies .mirror-badge", text: "1 to map"
  end

  def test_source_figures_are_compared_with_the_linked_objects
    MirrorMapping.create!(project_id: @project.id, connection_key: "key", module_key: "wiki", source_id: 1, destination_id: 1,
      source_fingerprint: "a", destination_fingerprint: "b")
    MirrorMapping.create!(project_id: @project.id, connection_key: "key", module_key: "wiki_attachments", source_id: 7, destination_id: 7,
      source_fingerprint: "a", destination_fingerprint: "b")
    wiki_tab
    assert_select "#mirror-module-statistics tbody tr:first-child td", text: "3"
    assert_select "#mirror-module-statistics tbody tr:first-child td a", text: "1"
    assert_select "#mirror-module-statistics tbody tr td", text: "Wiki attachments"
    assert_select "#mirror-not-linked", text: /2 source objects are not linked/
    assert_select "#mirror-module-last-run", text: /No synchronization has written this module yet/
  end

  def test_last_run_of_the_module_sums_its_actions
    events = [{ "module" => "wiki", "source_id" => 1, "action" => "create" }, { "module" => "wiki", "source_id" => 2, "action" => "create" },
      { "module" => "wiki", "source_id" => 3, "action" => "ignored" }, { "module" => "users", "source_id" => 5, "action" => "update" }]
    run = @project.mirror_sync_runs.create!(apply: true, trigger: "manual", status: "succeeded", finished_at: Time.current,
      module_totals: JSON.generate("users" => 1, "wiki" => 3), events: JSON.generate(events))
    # A preview writes nothing: it is not the last synchronization.
    @project.mirror_sync_runs.create!(apply: false, trigger: "manual", status: "succeeded", module_totals: JSON.generate("wiki" => 3))
    MirrorConflict.create!(project_id: @project.id, connection_key: "key", module_key: "wiki", source_id: 3, message: "Local edit")
    wiki_tab
    assert_select "#mirror-module-last-run a[href=?]", "/projects/ecookbook/mirror/synchronizations/#{run.id}"
    assert_select "#mirror-module-last-run", text: /2 created, 1 ignored/
    assert_select "#mirror-module-conflicts", text: "1 open conflicts"
  end

  # Checks compare the figures read with the references with this Redmine's state.
  def test_wiki_checks_oversized_files_and_existing_local_pages
    with_settings(attachment_max_size: "5120") do
      linked = WikiPage.find_by!(wiki_id: @project.wiki.id, title: "Another_page")
      MirrorMapping.create!(project_id: @project.id, connection_key: "key", module_key: "wiki", source_id: 2, destination_id: linked.id,
        source_fingerprint: "a", destination_fingerprint: "b")
      @setting.update!(source_catalog: @setting.source_catalog.merge("module_statistics" => { "wiki" => { "records" => 3,
        "sizes_kb" => { "6000" => 2, "10" => 1 }, "titles" => { "CookBook_documentation" => 1, "Another_page" => 1, "New_page" => 1 } } }))
      wiki_tab
      assert_select "#mirror-module-checks li", text: /2 source files exceed this Redmine's maximum attachment size \(5120 KB\)/
      assert_select "#mirror-module-checks li", text: /1 source pages already exist here without correspondence/
      # The fix is for administrators only; per-key figures stay out of the table.
      assert_select "#mirror-module-checks a[href*='tab=attachments']", count: 0
      assert_select "#mirror-module-statistics tbody tr", count: 2
    end
  end

  def test_watcher_checks_count_subscriptions_that_will_not_be_imported
    @setting.selected_modules = %w[issue_watchers]
    @setting.source_catalog = { "user" => { "7" => "Gone", "8" => "Locked", "9" => "Active" },
      "module_statistics" => { "issue_watchers" => { "records" => 4, "watchers" => 6, "watcher_users" => { "7" => 3, "8" => 2, "9" => 1 } } } }
    @setting.save!
    # Fixture user 5 is locked, user 2 active.
    [["7", "anonymous", nil], ["8", "existing", 5], ["9", "existing", 2]].each do |id, mode, destination|
      @project.mirror_reference_mappings.new(reference_type: "user", source_id: id, mode: mode, destination_id: destination).save!(validate: false)
    end
    get "/projects/ecookbook/settings/mirror", params: { mirror_tab: "issue_watchers" }
    assert_response :success
    assert_select "#mirror-module-checks li", text: /3 subscriptions belong to anonymized users/
    assert_select "#mirror-module-checks li", text: /2 subscriptions belong to users mapped to a locked or registered account/
  end

  def test_hierarchy_check_counts_pending_parents
    @setting.update!(selected_modules: %w[issue_hierarchy])
    MirrorPendingParent.create!(project_id: @project.id, connection_key: "key", source_id: 10, local_issue_id: 1, remote_parent_id: 11,
      status: "pending", checked_at: Time.current)
    get "/projects/ecookbook/settings/mirror", params: { mirror_tab: "issue_hierarchy" }
    assert_response :success
    assert_select "#mirror-module-checks li", text: /1 subtasks are waiting for their parent issue/
    assert_select "#mirror-module-checks a[href=?]", "/projects/ecookbook/mirror?tab=pending"
  end

  def test_catalog_without_figures_asks_for_a_refresh
    @setting.update!(source_catalog: { "user" => {} })
    wiki_tab
    assert_select "#mirror-module-overview .info", text: /to count the source objects/
  end
end
