# frozen_string_literal: true
# File: redmine_mirror/test/integration/mirror_configuration_test.rb
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

class MirrorConfigurationTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :trackers,
    :projects_trackers, :issue_statuses, :enumerations, :versions, :issue_categories, :boards, :repositories,
    :custom_fields, :custom_fields_projects, :custom_fields_trackers, :workflows

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 12)
    @setting.selected_modules = %w[issue_tracking time_tracking]
    @setting.api_key = "private-api-key"
    @setting.source_catalog = { "tracker" => { "1" => "Bug", "2" => "Remote tracker" }, "status" => { "1" => "Open" },
      "priority" => { "1" => "Normal" }, "user" => { "7" => "Remote Alice" }, "activity" => { "9" => "Development" } }
    @setting.catalog_status = "ready"
    @setting.save!
  end

  def settings(mirror_tab = nil, **params)
    get "/projects/ecookbook/settings/mirror", params: { mirror_tab: mirror_tab }.compact.merge(params)
    assert_response :success
  end

  def test_configuration_has_module_tabs_with_counters_and_never_displays_key
    log_user("admin", "admin")
    settings
    assert_select "#tab-mirror.selected"
    assert_select "#mirror-settings-subtabs a", count: 5
    assert_select "#mirror-settings-subtabs a[href$='mirror_tab=issue_tracking'] .mirror-badge", text: "4"
    assert_select "#mirror-settings-subtabs a[href$='mirror_tab=users'] .mirror-badge", text: "1"
    assert_select "input[name='connection[source_url]'][readonly]"
    assert_select 'input[name="connection[api_key]"]' do |inputs|
      assert inputs.first["value"].blank?
    end
    assert_no_match "private-api-key", response.body
    assert_select "a[href='/projects/ecookbook/mirror']", text: "Mirror page"
  end

  # Local users show their login, email and company, and the search covers them.
  def test_user_choices_show_login_email_and_company
    company = UserCustomField.create!(name: "Company", field_format: "string", visible: true)
    User.find(2).update!(custom_field_values: { company.id.to_s => "Acme" })
    log_user("admin", "admin")
    settings("users")
    assert_select "#mirror-table-user option", text: "John Smith (#2) — jsmith · jsmith@somenet.foo · Acme"
    with_settings plugin_redmine_mirror: { "user_company_field_id" => "none" } do
      settings("users")
      assert_select "#mirror-table-user option", text: "John Smith (#2) — jsmith · jsmith@somenet.foo"
    end
  end

  # A source reference with a single local namesake is preselected, not saved.
  def test_module_tab_preselects_namesakes_and_shows_only_its_tables
    log_user("admin", "admin")
    settings("issue_tracking")
    assert_select "#mirror-table-tracker tr.mirror-suggested select option[selected]", text: "Bug (#1)"
    assert_select "#mirror-table-tracker tr.mirror-unmapped", count: 1
    assert_select "#mirror-suggestions", text: /2 correspondences with the same name/
    assert_select "#mirror-table-user", count: 0
    assert_equal 0, @project.mirror_reference_mappings.count
  end

  def test_legacy_settings_gain_users_tab_and_preserve_anonymous_account
    @setting.update_columns(selected_modules: JSON.generate(["time_tracking"]),
      module_options: JSON.generate("time_tracking" => { "anonymous_user_id" => 42 }))
    log_user("admin", "admin")
    settings("users")
    assert_select "#mirror-table-user"
    assert_select "#mirror-table-tracker", count: 0
  end

  def test_custom_field_values_and_ignored_fields_are_shown
    field = IssueCustomField.create!(name: "Local list", field_format: "list", possible_values: ["Local A"], is_for_all: true)
    @setting.selected_modules = ["issue_custom_fields"]
    @setting.source_catalog = { "custom_field" => { "900" => "Remote list", "901" => "Remote ignored" }, "custom_field_definitions" => {
      "900" => { "field_format" => "list", "multiple" => false, "possible_values" => [{ "value" => "Remote [A]", "label" => "Remote [A]" }] } } }
    @setting.module_options = { "issue_custom_fields" => { "value_mappings" => { "900" => { RedmineMirror::Adapters::CustomFields.new.value_key("Remote [A]") => "Local A" } } } }
    @setting.save!
    @project.mirror_reference_mappings.create!(reference_type: "custom_field", source_id: 900, destination_id: field.id, mode: "existing")
    @project.mirror_reference_mappings.create!(reference_type: "custom_field", source_id: 901, mode: "ignore")
    log_user("admin", "admin")
    settings("issue_custom_fields")
    assert_select "table.mirror-custom-field-values tbody tr", count: 1
    assert_select 'select[name^="module_options[value_mappings]"] option[selected]', text: "Local A"
    assert_select '#mirror-custom_field-901 option[selected]', text: "Ignore this field"
  end

  def test_catalog_refresh_progress_reloads_the_page
    @setting.update_columns(catalog_status: "refreshing", catalog_requested_at: Time.current,
      catalog_progress: JSON.generate("step" => 1, "steps" => 2, "module" => "issue_tracking", "records" => 40, "at" => Time.current.iso8601))
    log_user("admin", "admin")
    settings
    assert_select "#mirror-catalog-status[data-mirror-reload]", text: /Step 1\/2: Issues, 40 records read/
  end

  def test_members_choose_among_allowed_sources_for_a_new_connection
    @setting.destroy
    log_user("jsmith", "jsmith")
    settings
    assert_select "#mirror-no-allowed-source"
    assert_select "input[type=submit][disabled]"
    with_settings(plugin_redmine_mirror: { "allowed_source_urls" => "https://source.example/redmine" }) do
      settings
      assert_select "select[name='connection[source_url]'] option", text: "https://source.example/redmine"
    end
  end

  def test_tab_is_hidden_without_permission_or_module
    Role.all.each { |role| %i[manage_mirror select_project_modules].each { |permission| role.remove_permission!(permission) } }
    log_user("jsmith", "jsmith")
    get "/projects/ecookbook/settings"
    assert_response :success
    assert_select "#tab-mirror", count: 0
    Role.find(1).add_permission!(:manage_mirror)
    @project.disable_module!(:mirror)
    get "/projects/ecookbook/settings"
    assert_select "#tab-mirror", count: 0
  end

  # The compatibility runner installs plugins that add project settings tabs with
  # alias_method chains and prepend, before and after Mirror (test/compatibility/plugins):
  # the page must render every tab. A 500 on the project settings went unnoticed once.
  COMPAT_PLUGINS = %w[aaa_mirror_compat_alias zzz_mirror_compat_alias zzz_mirror_compat_prepend].freeze

  def test_settings_page_keeps_the_tabs_of_other_plugins
    installed = COMPAT_PLUGINS.select { |name| Redmine::Plugin.installed?(name) }
    assert_equal COMPAT_PLUGINS, installed, "compatibility plugins missing" if ENV["MIRROR_COMPAT_PLUGINS"] == "1"
    log_user("admin", "admin")
    get "/projects/ecookbook/settings"
    assert_response :success
    assert_select "#tab-mirror"
    installed.each do |name|
      assert_select "#tab-#{name}"
      assert_select "##{name}-content"
    end
    get "/projects/ecookbook/settings/mirror", params: { mirror_tab: "issue_tracking" }
    assert_response :success
    assert_select "#mirror-table-tracker"
  end

  def test_other_settings_tabs_render_only_the_light_connection_view
    log_user("admin", "admin")
    get "/projects/ecookbook/settings/info"
    assert_response :success
    assert_select "#tab-content-mirror[style*='display:none'] #mirror-connection-form"
    assert_select "#tab-content-mirror .mirror-mapping-table", count: 0
  end
end
