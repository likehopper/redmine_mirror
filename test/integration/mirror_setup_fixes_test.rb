# frozen_string_literal: true
# File: redmine_mirror/test/integration/mirror_setup_fixes_test.rb
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
# The Mirror tab of the project settings: sub-tabs, mappings and permissions.

require_relative "../test_helper"
class MirrorSetupFixesTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :trackers,
    :projects_trackers, :issue_statuses, :enumerations, :custom_fields, :custom_fields_projects, :custom_fields_trackers

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    @project.disable_module!(:documents)
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 12)
    @setting.selected_modules = %w[issue_tracking wiki documents]
    @setting.api_key = "private-api-key"
    # The source project has no wiki; it has members, and categories this account cannot list.
    @setting.source_catalog = { "tracker" => { "1" => "Bug", "2" => "Remote tracker" }, "tracker_used" => %w[1 2],
      "source_modules" => %w[issue_tracking documents], "source_inventory" => { "project_members" => 3, "issue_categories" => nil, "project_versions" => 0 } }
    @setting.catalog_status = "ready"
    @setting.save!
    # Tracker 3 (Support request), mapped, then no longer used by the project.
    @project.mirror_reference_mappings.create!(reference_type: "tracker", source_id: 2, mode: "existing", destination_id: 3)
    @project.update!(tracker_ids: [1, 2])
  end

  def fix(params)
    post "/projects/ecookbook/mirror/settings/fix", params: params.merge(back_url: "/projects/ecookbook/settings/mirror")
  end

  # Fixes are buttons that come back here, not links to Redmine's own settings tabs; the
  # unselect button names the Mirror modules it would unselect.
  def test_fixes_come_back_and_name_what_they_unselect
    @setting.update!(source_catalog: @setting.source_catalog.merge("tracker" => { "1" => "Bug", "2" => "Remote tracker", "4" => "Support request" },
      "tracker_used" => %w[1 2 4]))
    @project.mirror_reference_mappings.where(reference_type: "tracker").delete_all
    log_user("admin", "admin")
    get "/projects/ecookbook/settings/mirror"
    assert_select "#mirror-checklist li", text: /The tracker Support request exists in Redmine/ do
      assert_select "input[name=target][value='3']"
      assert_select "a", count: 0
    end
    assert_select "#mirror-checklist li", text: /Documents module is disabled on this project/ do
      assert_select "a", count: 0
    end
    assert_select "#mirror-checklist form.mirror-fix-form input[name=target][value=wiki] ~ button, #mirror-checklist form.mirror-fix-form input[type=submit][value='Do not import: Wiki']"
    fix(fix: "enable_tracker", target: 3)
    assert_redirected_to "/projects/ecookbook/settings/mirror"
    assert_includes @project.reload.tracker_ids, 3
    # Only a tracker named like a source tracker.
    tracker = Tracker.create!(name: "Unrelated", default_status_id: 1)
    fix(fix: "enable_tracker", target: tracker.id)
    assert flash[:error]
    refute_includes @project.reload.tracker_ids, tracker.id
  end

  def test_the_connection_tab_proposes_one_click_fixes
    log_user("admin", "admin")
    get "/projects/ecookbook/settings/mirror"
    assert_response :success
    assert_select "#mirror-checklist li", text: /Wiki module is not enabled in the source project/
    assert_select "#mirror-checklist form.mirror-fix-form input[name=target][value=wiki]"
    assert_select "#mirror-checklist li", text: /Documents module is disabled on this project/ do
      assert_select "button[data-fix=enable_module], input[data-fix=enable_module]"
    end
    assert_select "#mirror-checklist li", text: /Support request/
    assert_select "#mirror-checklist li", text: /Members \(3\)/
    assert_select "#mirror-checklist li", text: /Issue categories/, count: 0
    assert_select "label.mirror-module-source-off", text: /Wiki/
    # Greyed: a module missing on the source cannot be selected, a selected one unselected.
    assert_select "#connection_modules_wiki[checked]:not([disabled])"
    assert_select "label.mirror-module-source-off input[disabled]"
    assert_select "label.mirror-module-source-off input:not([checked]):not([disabled])", count: 0
  end

  def test_fixes_enable_unselect_and_select
    log_user("admin", "admin")
    fix(fix: "enable_module", target: "documents")
    assert_redirected_to "/projects/ecookbook/settings/mirror"
    assert @project.reload.module_enabled?(:documents)
    fix(fix: "unselect_module", target: "wiki")
    assert_equal [302, nil, "Successful update."], [response.status, flash[:error], flash[:notice]]
    assert_equal %w[users issue_tracking documents], @setting.reload.selected_modules
    fix(fix: "enable_trackers")
    assert_includes @project.reload.tracker_ids, 3
    fix(fix: "select_module", target: "project_members")
    assert_includes @setting.reload.selected_modules, "project_members"
    assert_equal "pending", @setting.catalog_status
    # A module unknown, or one that would leave nothing to import.
    fix(fix: "select_module", target: "nothing")
    assert flash[:error]
    fix(fix: "enable_module", target: "boards")
    assert flash[:error]
  end

  def test_mapped_fields_are_enabled_in_the_project
    field = IssueCustomField.create!(name: "Remote only", field_format: "string", is_for_all: false, trackers: Tracker.all, projects: [@project])
    @setting.update!(selected_modules: %w[issue_tracking issue_custom_fields], source_catalog: @setting.source_catalog.merge("custom_field" => { "40" => "Remote only" }))
    @project.mirror_reference_mappings.create!(reference_type: "custom_field", source_id: 40, mode: "existing", destination_id: field.id)
    # The field was later removed from the project.
    field.projects.delete(@project)
    log_user("admin", "admin")
    get "/projects/ecookbook/settings/mirror"
    assert_select "#mirror-checklist input[name=target][value='#{field.id}']"
    fix(fix: "enable_custom_field", target: field.id)
    assert_includes @project.reload.issue_custom_field_ids, field.id
    other = IssueCustomField.create!(name: "Not mapped", field_format: "string", is_for_all: false)
    fix(fix: "enable_custom_field", target: other.id)
    assert flash[:error]
    refute_includes @project.reload.issue_custom_field_ids, other.id
  end

  # Each fix needs the permission Redmine itself asks for.
  def test_fixes_need_the_redmine_permissions
    Role.find(1).add_permission!(:manage_mirror)
    Role.find(1).remove_permission!(:edit_project)
    Role.find(1).remove_permission!(:select_project_modules)
    log_user("jsmith", "jsmith")
    fix(fix: "enable_trackers")
    assert_response 403
    refute_includes @project.reload.tracker_ids, 3
    fix(fix: "enable_module", target: "documents")
    assert_response 403
    refute @project.reload.module_enabled?(:documents)
  end
  # Anonymized users with time entries need an account to receive them.
  def test_anonymized_time_without_account_is_pointed_out
    @setting.update!(selected_modules: %w[issue_tracking time_tracking], source_catalog: @setting.source_catalog.merge("user" => { "70" => "Departed" }))
    @project.mirror_reference_mappings.create!(reference_type: "user", source_id: 70, mode: "anonymous")
    log_user("admin", "admin")
    get "/projects/ecookbook/settings/mirror"
    assert_select "#mirror-checklist li", text: /no account receives them/
    with_settings(plugin_redmine_mirror: { "anonymous_time_user_id" => "2" }) do
      get "/projects/ecookbook/settings/mirror"
      assert_select "#mirror-checklist li", text: /no account receives them/, count: 0
      assert_select "#mirror-checklist li", text: /is not an active member/, count: 0
    end
  end

  # A users table can leave thousands of names unmapped: the checklist reads the local
  # accounts once, not once per name, and still points out an account outside the project.
  def test_checklist_reads_local_accounts_once
    Role.find(1).add_permission!(:manage_mirror)
    Role.find(1).remove_permission!(:manage_members)
    outsider = User.active.where(type: "User").where.not(id: @project.members.select(:user_id)).where.not(id: 1).first
    member = @project.users.active.first
    sql_count = lambda do |extra|
      users = { "2001" => outsider.name, "2002" => member.name }
      extra.times { |index| users[(3000 + index).to_s] = "Remote person #{index}" }
      @setting.update!(source_catalog: @setting.source_catalog.merge("user" => users, "user_used" => users.keys))
      # Cached reads count too: the old code read the same accounts again for each name.
      count = 0
      counter = ->(*, payload) { count += 1 if payload[:name] == "User Load" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get "/projects/ecookbook/settings/mirror" }
      assert_response :success
      count
    end
    log_user("jsmith", "jsmith")
    few = sql_count.call(2)
    assert_select "#mirror-checklist li", text: /#{outsider.name} has an account here but is not a member/
    assert_select "#mirror-checklist li", text: /#{member.name} has an account here/, count: 0
    assert_operator sql_count.call(60) - few, :<, 5
  end
end
