# frozen_string_literal: true
# File: redmine_mirror/test/system/mirror_navigation_test.rb
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
require File.expand_path("../../../../test/application_system_test_case", __dir__)
class MirrorNavigationTest < ApplicationSystemTestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def test_admin_can_open_mirror_project_tab
    Project.find(1).enable_module!(:mirror)
    log_user("admin", "admin")
    visit "/projects/ecookbook/mirror"
    assert_current_path "/projects/ecookbook/mirror/settings"
    assert_selector "#mirror-settings-tabs"
    assert_selector 'input[name="connection[source_url]"]' 
  end
end

class MirrorMappingSystemTest < ApplicationSystemTestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def test_admin_saves_anonymous_mapping_in_project_module_tab
    project = Project.find(1)
    project.enable_module!(:mirror)
    setting = MirrorProjectSetting.new(project: project, source_url: "https://source.example", source_project_id: 12)
    setting.selected_modules = ["issue_tracking"]
    setting.api_key = "hidden-system-test-key"
    setting.source_catalog = { "user" => { "7" => "Remote Alice" } }
    setting.save!
    log_user("admin", "admin")
    visit "/projects/ecookbook/mirror/settings"
    assert_no_text "hidden-system-test-key"
    find(".tabs a[href*='tab=users']").click
    select "Anonymize", from: "mirror-user-7"
    click_button "Save"
    assert_selector "#flash_notice"
    assert_equal "anonymous", project.mirror_reference_mappings.find_by!(reference_type: "user", source_id: 7).mode
    visit "/projects/ecookbook/mirror/settings?tab=users"
    assert_select_value = find("#mirror-user-7").value
    assert_equal "anonymous", assert_select_value
  end
end

class MirrorSynchronizationSystemTest < ApplicationSystemTestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def test_admin_configures_schedule_and_queues_preview
    project = Project.find(1)
    project.enable_module!(:mirror)
    setting = MirrorProjectSetting.new(project: project, source_url: "https://remote.example", source_project_id: 12)
    setting.selected_modules = ["issue_tracking"]
    setting.api_key = "system-test-api-key"
    setting.save!
    log_user("admin", "admin")
    visit "/projects/ecookbook/mirror/settings?tab=synchronization"
    check "schedule-enabled"
    select "Every 15 minutes", from: "schedule-interval"
    click_button "Save"
    assert_selector "#flash_notice"
    assert setting.reload.auto_sync_enabled?
    click_button "Run preview"
    assert_text "Queued"
    assert_equal "queued", project.mirror_sync_runs.first!.status
  end
end

class MirrorHistorySystemTest < ApplicationSystemTestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def test_history_and_log_filters_are_accessible_from_tabs
    project = Project.find(1)
    project.enable_module!(:mirror)
    setting = MirrorProjectSetting.new(project: project, source_url: "https://source.example", source_project_id: 12)
    setting.selected_modules = ["time_tracking"]
    setting.api_key = "system-key"
    setting.save!
    run = project.mirror_sync_runs.create!(trigger: "manual", status: "succeeded", events: JSON.generate([
      { module: "issue_tracking", source_id: 1, action: "create" },
      { module: "time_tracking", source_id: 2, action: "unchanged" }]))
    log_user("admin", "admin")
    visit "/projects/ecookbook/mirror/settings?tab=history"
    select "Succeeded", from: "status"
    click_button "Apply"
    # Wait for the filtered navigation before clicking a link from the replacement document.
    assert_current_path(/status=succeeded/)
    within("#mirror-history") { click_link run.id.to_s }
    assert_current_path "/projects/ecookbook/mirror/synchronizations/#{run.id}", ignore_query: true
    select "Time tracking", from: "module_key"
    click_button "Apply"
    assert_current_path(/module_key=time_tracking/)
    assert_selector "#mirror-log tbody tr", count: 1
    assert_text "unchanged"
    assert_no_selector "#mirror-log td", text: "issue_tracking"
  end
end

class MirrorIssueStateSystemTest < ApplicationSystemTestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def test_hierarchy_and_watchers_have_module_tabs_and_user_mapping_link
    project = Project.find(1)
    project.enable_module!(:mirror)
    setting = MirrorProjectSetting.new(project: project, source_url: "https://source.example", source_project_id: 12)
    setting.selected_modules = %w[issue_hierarchy issue_watchers]
    setting.api_key = "hidden-system-key"
    setting.save!
    log_user("admin", "admin")
    visit "/projects/ecookbook/mirror/settings"
    assert_selector 'input[value="issue_hierarchy"]:checked'
    assert_selector 'input[value="issue_watchers"]:checked'
    find("#mirror-settings-sections a[href*='tab=users']").click
    within("#mirror-settings-subtabs") { click_link "Issue hierarchy" }
    assert_text "Native Redmine cross-project subtask rules apply"
    assert_selector "#mirror-pending-parents"
    within("#mirror-settings-subtabs") { click_link "Issue watchers" }
    assert_text "Local subscriptions are preserved"
    assert_selector 'a[href*="tab=users"]'
    assert_no_text "hidden-system-key"
  end
end

class MirrorCustomFieldSystemTest < ApplicationSystemTestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def test_admin_maps_field_then_list_values
    project = Project.find(1)
    project.enable_module!(:mirror)
    field = IssueCustomField.create!(name: "Local options", field_format: "list", possible_values: ["Local A"], is_for_all: true)
    setting = MirrorProjectSetting.new(project: project, source_url: "https://source.example", source_project_id: 12)
    setting.selected_modules = ["issue_custom_fields"]
    setting.api_key = "hidden-cf-system-key"
    setting.source_catalog = { "custom_field" => { "900" => "Remote options" }, "custom_field_definitions" => {
      "900" => { "field_format" => "list", "multiple" => false, "possible_values" => [{ "value" => "Remote A", "label" => "Remote A" }] } } }
    setting.save!
    log_user("admin", "admin")
    visit "/projects/ecookbook/mirror/settings?tab=issue_custom_fields"
    select "Local options (##{field.id})", from: "mirror-custom_field-900"
    click_button "Save"
    assert_selector "#flash_notice"
    hash = RedmineMirror::Adapters::CustomFields.new.value_key("Remote A")
    select "Local A", from: "mirror-cf-value-900-#{hash}"
    click_button "Save"
    assert_selector "#flash_notice"
    assert_selector "#mirror-cf-value-900-#{hash} option[selected]", text: "Local A"
    assert_equal "Local A", setting.reload.module_options.dig("issue_custom_fields", "value_mappings", "900", hash)
    select "Ignore this field", from: "mirror-custom_field-900"
    click_button "Save"
    assert_selector "#flash_notice"
    assert_no_selector "table.mirror-custom-field-values"
    assert_equal "ignore", project.mirror_reference_mappings.find_by!(reference_type: "custom_field", source_id: 900).mode
    assert_no_text "hidden-cf-system-key"
  end
end

class MirrorConflictSystemTest < ApplicationSystemTestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules
  def test_admin_can_keep_local_object_and_recheck
    project = Project.find(1)
    project.enable_module!(:mirror)
    setting = MirrorProjectSetting.new(project: project, source_url: "https://source.example", source_project_id: 12)
    setting.api_key = "hidden-conflict-key"
    setting.selected_modules = ["issue_tracking"]
    setting.save!
    MirrorMapping.create!(project_id: project.id, connection_key: "test", module_key: "issue_tracking", source_id: 99, destination_id: 1, source_fingerprint: "a", destination_fingerprint: "b")
    conflict = project.mirror_conflicts.create!(connection_key: "test", module_key: "issue_tracking", source_id: 99, destination_id: 1, message: "Local modification detected")
    log_user("admin", "admin")
    visit "/projects/ecookbook/mirror/settings?tab=conflicts"
    assert_text "Local modification detected"
    accept_confirm { click_button "Keep local object" }
    assert_text "Kept locally"
    assert_equal "ignored", conflict.reload.status
    click_button "Recheck after correction"
    assert_text "Open"
    assert_equal "open", conflict.reload.status
    assert_no_text "hidden-conflict-key"
  end
end

class MirrorWrappingTabsSystemTest < ApplicationSystemTestCase
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules
  def test_all_module_tabs_remain_visible_on_narrow_screens
    User.find(1).update_column(:language, "fr")
    project = Project.find(1)
    project.enable_module!(:mirror)
    setting = MirrorProjectSetting.new(project: project, source_url: "https://source.example", source_project_id: 12)
    setting.selected_modules = RedmineMirror::REGISTRY.keys
    setting.api_key = "hidden-tabs-key"
    setting.save!
    log_user("admin", "admin")
    visit "/projects/ecookbook/mirror/settings?tab=users"
    [800, 1280, 1920].each do |width|
      page.driver.browser.manage.window.resize_to(width, 900)
      assert_selector "#mirror-settings-subtabs a", count: RedmineMirror::REGISTRY.keys.size + 1
      assert page.evaluate_script(<<~JS), "Tabs overflow at width #{width}"
        (() => {
          const group = document.querySelector('#mirror-settings-subtabs').getBoundingClientRect();
          return [...document.querySelectorAll('#mirror-settings-subtabs a')].every(link => {
            const bounds = link.getBoundingClientRect();
            return bounds.top >= group.top && bounds.bottom <= group.bottom + 1 && bounds.left >= group.left && bounds.right <= group.right + 1;
          });
        })()
      JS
    end
  ensure
    page.driver.browser.manage.window.resize_to(1280, 900)
  end
end
