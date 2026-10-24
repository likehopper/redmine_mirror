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

  # The references to map are shown first; the mapped ones and all of them on request.
  def test_filter_shows_references_to_map_mapped_or_all
    @project.mirror_reference_mappings.create!(reference_type: "tracker", source_id: 2, mode: "existing", destination_id: @project.trackers.first.id)
    log_user("admin", "admin")
    settings("issue_tracking")
    assert_select "#mirror-mapping-filter strong", text: "to map (3)"
    assert_select "#mirror-tracker-1"
    assert_select "#mirror-tracker-2", count: 0
    settings("issue_tracking", mirror_filter: "mapped")
    assert_select "#mirror-mapping-filter strong", text: "mapped (1)"
    assert_select "#mirror-tracker-1", count: 0
    assert_select "#mirror-tracker-2"
    settings("issue_tracking", mirror_filter: "all")
    assert_select "#mirror-tracker-1"
    assert_select "#mirror-tracker-2"
    assert_select "input[type=hidden][name=mirror_filter][value=all]"
  end

  # Long lists are sent once per table: each row only holds the empty choice and its value.
  def test_long_user_lists_are_shared_by_the_rows
    role = Role.givable.first
    users = (0..12).map { |number| User.create!(login: "mirror-long-#{number}", firstname: "Long", lastname: "List #{number}", mail: "mirror-long-#{number}@example.test") }
    alice = User.create!(login: "remote-alice", firstname: "Remote", lastname: "Alice", mail: "remote-alice@example.test")
    (users + [alice]).each { |user| Member.create!(project: @project, principal: user, roles: [role]) }
    log_user("admin", "admin")
    settings("users")
    assert_equal ["", alice.id.to_s], css_select("#mirror-user-7 option").map { |option| option["value"] }
    assert_select "#mirror-user-7[data-choices=mirror-choices-user]"
    choices = JSON.parse(css_select("script#mirror-choices-user").first.text)
    assert_includes choices.map(&:last), "2"
    assert_not_includes choices.map(&:last), ""
  end

  # Local users show their login, email and company, and the search covers them.
  def test_user_choices_show_login_email_and_company
    company = UserCustomField.create!(name: "Company", field_format: "string", visible: true)
    User.find(2).update!(custom_field_values: { company.id.to_s => "Acme" })
    log_user("admin", "admin")
    settings("users")
    assert_select "#mirror-table-user option", text: "John Smith (#2) — jsmith · jsmith@somenet.foo · Acme"
    # Anonymizing is a checkbox beside the field, not one of its choices.
    assert_equal "", css_select("#mirror-user-7 option").first["value"]
    assert_select "#mirror-user-7 option[value=anonymous]", count: 0
    assert_select "input[type=checkbox][name='special_mappings[user][7]'][value=anonymous]"
    with_settings plugin_redmine_mirror: { "user_company_field_id" => "none" } do
      settings("users")
      assert_select "#mirror-table-user option", text: "John Smith (#2) — jsmith · jsmith@somenet.foo"
    end
  end

  # Tabs without references have no Save button; a disabled project module is reported.
  def test_wiki_tab_warns_about_the_disabled_module_and_members_option_clears_the_counter
    @setting.update!(selected_modules: %w[wiki project_members], source_catalog: { "user" => {}, "role" => { "41" => "Remote reviewer" } })
    @project.disable_module!(:wiki)
    log_user("admin", "admin")
    settings("wiki")
    assert_select "#mirror-project-module-disabled a[href='/projects/ecookbook/settings/modules']"
    assert_select "#mirror-mappings-form input[type=submit]", count: 0
    assert_select "#mirror-settings-subtabs a[href$='mirror_tab=project_members'] .mirror-badge", text: "1"
    patch "/projects/ecookbook/mirror/settings/modules/project_members", params: { module_options: { unmapped: "skip" } }
    assert_equal "skip", @setting.reload.module_options.dig("project_members", "unmapped")
    settings("project_members")
    assert_select "#mirror-settings-subtabs a[href$='mirror_tab=project_members'] .mirror-badge", count: 0
    assert_select "#members-unmapped option[selected]", text: "Do not give them"
  end

  # Document categories are mapped to local ones, namesakes preselected; saving clears the counter.
  def test_documents_tab_maps_categories
    @setting.update!(selected_modules: %w[documents], source_catalog: { "user" => {}, "document_category" => { "71" => "Technical documentation", "72" => "Remote specs" } })
    log_user("admin", "admin")
    settings("documents")
    assert_select "#mirror-settings-subtabs a[href$='mirror_tab=documents'] .mirror-badge", text: "2"
    assert_select "#mirror-table-document_category tr.mirror-suggested select option[selected]", text: "Technical documentation (#3)"
    assert_select "#mirror-table-document_category option", text: /Inactive Document Category/, count: 0
    assert_select "p", text: /must run Redmine Mirror.*share Documents/
    patch "/projects/ecookbook/mirror/settings/modules/documents", params: { mappings: { "document_category" => { "71" => "3", "72" => "2" } } }
    assert_equal({ "71" => 3, "72" => 2 }, @project.mirror_reference_mappings.where(reference_type: "document_category").to_h { |row| [row.source_id.to_s, row.destination_id] })
    settings("documents")
    assert_select "#mirror-settings-subtabs a[href$='mirror_tab=documents'] .mirror-badge", count: 0
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
    assert_select "#mirror-custom_field-901-ignore[checked]"
    assert_select "#mirror-custom_field-901 option[value=ignore]", count: 0
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

  # Once sources are allowed, administrators choose among them too; while none is, they
  # may enter any URL.
  def test_administrators_choose_among_allowed_sources_once_listed
    @setting.destroy
    log_user("admin", "admin")
    settings
    assert_select "input[type=text][name='connection[source_url]']"
    with_settings(plugin_redmine_mirror: { "allowed_source_urls" => "https://source.example/redmine" }) do
      settings
      assert_select "select[name='connection[source_url]'] option", text: "https://source.example/redmine"
      assert_select "input[type=text][name='connection[source_url]']", count: 0
      patch "/projects/ecookbook/mirror/settings/connection", params: { connection: { source_url: "https://other.example", source_project_id: "12", api_key: "key" } }
      assert_equal I18n.t(:text_mirror_source_not_allowed), flash[:error]
      assert_nil @project.reload.mirror_project_setting
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

  # Source users whose email the source shares: preselected by email, or created by a
  # members manager as registered accounts when the administrator allows it.
  def test_members_managers_create_registered_accounts_from_shared_source_users
    Role.find(1).add_permission!(:manage_mirror)
    company = UserCustomField.create!(name: "Company", field_format: "string")
    details = {
      "7" => { "login" => "ralice", "firstname" => "Alice", "lastname" => "Remote", "mail" => "alice@source.example", "company" => "ACME" },
      "8" => { "login" => "jsmith", "firstname" => "Bob", "lastname" => "Remote", "mail" => "bob@source.example" },
      "9" => { "login" => "john", "firstname" => "John", "lastname" => "Smith", "mail" => "JSmith@somenet.foo" } }
    @setting.update!(source_catalog: @setting.source_catalog.merge(
      "user" => { "7" => "Remote Alice", "8" => "Remote Bob", "9" => "Remote John" }, "user_details" => details))
    log_user("jsmith", "jsmith")
    settings("users")
    assert_select "#mirror-table-user em.mirror-source-user", text: "ralice · alice@source.example · ACME"
    # Same email first: John is jsmith here.
    assert_select "#mirror-user-9 option[selected][value='2']"
    assert_select "#mirror-table-user em.mirror-suggestion", text: "proposed: same email"
    assert_select "#mirror-user-creation-off"
    # Without details from the source, only those who may create accounts see why.
    @setting.update!(source_catalog: @setting.source_catalog.except("user_details").merge("user_details_refusal" => "not_shared"))
    settings("users")
    assert_select "#mirror-user-creation", count: 0
    with_settings(plugin_redmine_mirror: { "user_creation_enabled" => "1" }) do
      settings("users")
      assert_select "#mirror-user-details-refused", text: /Data not shared/
    end
    @setting.update!(source_catalog: @setting.source_catalog.except("user_details_refusal").merge("user_details" => details))
    post "/projects/ecookbook/mirror/settings/users", params: { source_user_ids: ["7"] }
    assert_equal 0, User.where(login: "ralice").count

    with_settings(plugin_redmine_mirror: { "user_creation_enabled" => "1" }) do
      settings("users")
      assert_select "table.mirror-user-creation tbody tr", count: 2
      assert_select "#mirror-create-user-9", count: 0
      ActionMailer::Base.deliveries.clear
      post "/projects/ecookbook/mirror/settings/users", params: { source_user_ids: %w[7 8], role_ids: ["2"] }
      assert_redirected_to "/projects/ecookbook/settings/mirror?mirror_tab=users#mirror-user-creation"
      alice = User.find_by(login: "ralice")
      assert alice, flash[:error]
      assert_equal [User::STATUS_REGISTERED, "alice@source.example", "ACME"], [alice.status, alice.mail, alice.custom_field_value(company)]
      assert_equal alice.id, @project.mirror_reference_mappings.find_by(reference_type: "user", source_id: 7).destination_id
      assert_equal [2], @project.memberships.find_by(user_id: alice.id).role_ids
      assert ActionMailer::Base.deliveries.any? { |mail| mail.bcc.to_a.include?("admin@somenet.foo") || mail.to.to_a.include?("admin@somenet.foo") }
      # Bob's login is taken: nothing is created for him.
      assert_match(/Bob Remote/, flash[:error])
      assert_nil @project.mirror_reference_mappings.find_by(reference_type: "user", source_id: 8)
      post "/projects/ecookbook/mirror/settings/users", params: { source_user_ids: %w[7] }
      assert_match(/already mapped/, flash[:error])
      # A role the user may not give is refused.
      Role.find(1).update!(all_roles_managed: false)
      post "/projects/ecookbook/mirror/settings/users", params: { source_user_ids: %w[8], role_ids: ["2"] }
      assert_equal 1, User.where(status: User::STATUS_REGISTERED, firstname: %w[Alice Bob]).count
    end
  end

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
