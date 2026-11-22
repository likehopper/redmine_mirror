# frozen_string_literal: true
# File: redmine_mirror/test/integration/mirror_source_settings_test.rb
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
# Verify the Mirror source tab (sharing, access log) and the administrator's switch and activity.

require_relative "../test_helper"

class MirrorSourceSettingsTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :documents, :enumerations

  SESSION = "fedcba9876543210fedcba9876543210"

  def setup
    @project = Project.find(1)
    Role.find(1).add_permission!(:manage_mirror_source)
    Role.find(1).add_permission!(:view_mirror_source_log)
  end

  def log_access(action, **attributes)
    MirrorSourceAccess.create!({ project: @project, user_id: 2, session_key: SESSION, purpose: "preview", remote_ip: "192.0.2.7",
      action: action, created_at: Time.current }.merge(attributes))
  end

  # Each lock in place or missing, and what each authorized account lacks.
  def test_access_status_names_each_missing_lock_and_account_gap
    @project.enable_module!(:mirror_source)
    Role.find(1).remove_permission!(:view_private_notes)
    setting = MirrorSourceSetting.create!(project: @project, shared_modules: %w[documents], authorized_user_ids: [2, 1])
    log_user("jsmith", "jsmith")
    with_settings(plugin_redmine_mirror: Setting.plugin_redmine_mirror.merge("source_enabled" => "1", "source_allowed_addresses" => "127.0.0.1")) do
      get "/projects/ecookbook/settings/mirror_source"
      assert_select "#mirror-source-status-summary.warning"
      assert_select "#mirror-source-status-addresses.mirror-missing"
      assert_select "#mirror-source-status-key.mirror-missing"
      assert_select "#mirror-source-status-accounts li", text: /administrator account/
      assert_select "#mirror-source-status-accounts li", text: /incremental feed refused.*View private notes/m
      setting.update!(client_addresses: "127.0.0.1", client_key: "a" * 43, authorized_user_ids: [2])
      Role.find(1).add_permission!(:view_private_notes)
      get "/projects/ecookbook/settings/mirror_source"
      assert_select "#mirror-source-status-summary.mirror-source-open"
      assert_select "#mirror-source-status-key.mirror-ok"
    end
  end

  def test_tab_appears_with_the_module_and_saves_the_shared_data
    log_user("jsmith", "jsmith")
    get "/projects/ecookbook/settings"
    assert_select "#tab-mirror_source", count: 0
    @project.enable_module!(:mirror_source)
    get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
    assert_select "#tab-mirror_source"
    assert_select "#mirror-source-disabled"
    assert_select "#mirror-source-share-documents:not([checked])"
    patch "/projects/ecookbook/mirror_source", params: { shared_modules: ["", "documents", "unknown"],
      client_addresses: "192.0.2.10\n2001:db8::/64", authorized_user_ids: [2, 1] }
    assert_redirected_to "/projects/ecookbook/settings/mirror_source"
    setting = @project.reload.mirror_source_setting
    assert_equal %w[documents], setting.shared_modules
    assert_equal ["192.0.2.10", "2001:db8::/64"], setting.client_addresses.lines(chomp: true)
    assert_equal [2], setting.authorized_user_ids
    get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
    assert_select "#mirror-source-client-addresses", text: /192\.0\.2\.10/
    assert_select "#mirror-source-authorized-users option[value='2'][selected]"
    patch "/projects/ecookbook/mirror_source", params: { shared_modules: [""], client_addresses: "192.0.2.10", authorized_user_ids: [2] }
    assert_empty @project.reload.mirror_source_setting.shared_modules
  end

  def test_invalid_client_address_is_not_saved
    @project.enable_module!(:mirror_source)
    setting = MirrorSourceSetting.create!(project: @project, client_addresses: "192.0.2.10", authorized_user_ids: [2])
    log_user("jsmith", "jsmith")
    patch "/projects/ecookbook/mirror_source", params: { shared_modules: ["documents"], client_addresses: "not-an-address", authorized_user_ids: [2] }
    assert_redirected_to "/projects/ecookbook/settings/mirror_source"
    assert_match(/invalid/i, flash[:error])
    assert_equal "192.0.2.10", setting.reload.client_addresses
  end

  # Data whose Redmine module the project has not enabled is greyed; a checked one can
  # still be unchecked.
  def test_data_without_its_project_module_is_greyed
    @project.enable_module!(:mirror_source)
    @project.disable_module!(:news)
    MirrorSourceSetting.create!(project: @project, shared_modules: %w[documents])
    log_user("jsmith", "jsmith")
    get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
    assert_select "#mirror-source-share-news[disabled]"
    assert_select "label.mirror-module-source-off", text: /News module is not enabled/
    assert_select "#mirror-source-share-documents[checked]:not([disabled])"
  end

  # The sharing reaches the subprojects where the person may enable modules and configure
  # Mirror source, limited to the data their own modules hold.
  def test_sharing_applies_to_the_subprojects_the_person_manages
    @project.enable_module!(:mirror_source)
    MirrorSourceSetting.create!(project: @project, shared_modules: %w[documents news],
      client_addresses: "192.0.2.10", authorized_user_ids: [2, 1], client_key_digest: "a" * 64)
    Project.find(3).enable_module!(:documents)
    Project.find(3).disable_module!(:news)
    %i[documents news].each { |name| Project.find(5).enable_module!(name) }
    log_user("admin", "admin")
    post "/projects/ecookbook/mirror_source/subprojects"
    assert_redirected_to "/projects/ecookbook/settings/mirror_source"
    [3, 4, 5, 6].each { |id| assert Project.find(id).module_enabled?(:mirror_source), "project #{id}" }
    assert_equal %w[documents], Project.find(3).mirror_source_setting.shared_modules
    assert_equal %w[documents news], Project.find(5).mirror_source_setting.shared_modules.sort
    child_setting = Project.find(5).mirror_source_setting
    assert_equal "192.0.2.10", child_setting.client_addresses
    assert_equal [1, 2], child_setting.authorized_user_ids
    assert_equal "a" * 64, child_setting.client_key_digest
  end

  # Each subproject: what matches this project, what differs or is still missing, and
  # its last destination access, with links to its settings and its access log.
  def test_subprojects_summary_compares_each_setting_and_shows_the_last_access
    @project.enable_module!(:mirror_source)
    MirrorSourceSetting.create!(project: @project, shared_modules: %w[documents],
      client_addresses: "192.0.2.10", authorized_user_ids: [2], client_key_digest: "a" * 64)
    [3, 4].each { |id| %i[mirror_source documents].each { |name| Project.find(id).enable_module!(name) } }
    MirrorSourceSetting.create!(project: Project.find(3), shared_modules: %w[documents],
      client_addresses: "192.0.2.10", authorized_user_ids: [2], client_key_digest: "a" * 64)
    MirrorSourceSetting.create!(project: Project.find(4), shared_modules: %w[documents],
      client_addresses: "198.51.100.1", authorized_user_ids: [2])
    log_access("refused", project: Project.find(3), reason: "client_key")
    Project.find(6).update_column(:status, Project::STATUS_CLOSED)
    log_user("admin", "admin")
    get "/projects/ecookbook/settings/mirror_source"
    assert_select "#mirror-source-subproject-3" do
      assert_select "a[href='/projects/subproject1/settings/mirror_source']"
      %w[addresses accounts key modules].each { |part| assert_select "td.mirror-source-#{part}.mirror-source-same" }
      assert_select "td.mirror-source-last-access a[href='/projects/subproject1/mirror_source']"
      assert_select "td.mirror-source-last-access", text: /Refused: Mirror application key not authorized/
    end
    assert_select "#mirror-source-subproject-4" do
      assert_select "td.mirror-source-addresses.mirror-source-custom"
      assert_select "td.mirror-source-accounts.mirror-source-same"
      assert_select "td.mirror-source-key.mirror-source-missing"
      assert_select "td.mirror-source-last-access", text: /No access yet/
    end
    assert_select "#mirror-source-subproject-5 td.mirror-source-disabled", text: "Mirror source not enabled"
    assert_select "#mirror-source-subproject-6 td.mirror-source-disabled", text: /closed project/
  end

  def test_subprojects_without_the_permissions_are_left_as_they_are
    @project.enable_module!(:mirror_source)
    MirrorSourceSetting.create!(project: @project, shared_modules: %w[documents])
    log_user("jsmith", "jsmith")
    post "/projects/ecookbook/mirror_source/subprojects"
    # jsmith manages the private child (5), not the public subprojects he only sees.
    assert Project.find(5).module_enabled?(:mirror_source)
    refute Project.find(3).module_enabled?(:mirror_source)
    assert_nil Project.find(3).mirror_source_setting
    assert_match(/left as they were/, flash[:notice])
  end

  def test_members_without_the_permission_cannot_change_the_sharing
    @project.enable_module!(:mirror_source)
    log_user("dlopper", "foo")
    patch "/projects/ecookbook/mirror_source", params: { shared_modules: ["documents"] }
    assert_response :forbidden
    assert_nil @project.reload.mirror_source_setting
  end

  def test_log_lists_sessions_then_what_one_session_received
    @project.enable_module!(:mirror_source)
    log_access("list", object_count: 2, details: JSON.generate("kind" => "documents"))
    log_access("download", object_count: 1, bytes: 2048, details: JSON.generate("kind" => "documents"))
    log_access("refused", reason: "not_shared")
    log_user("jsmith", "jsmith")
    get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
    assert_select "#mirror-source-form"
    assert_select "table.mirror-source-sessions", count: 0
    get "/projects/ecookbook/mirror_source"
    assert_no_match(/Translation missing/, response.body)
    assert_select "#main-menu a[href='/projects/ecookbook/mirror_source']", text: "Mirror source"
    assert_select "#mirror-source-filters"
    assert_select "table.mirror-source-sessions tbody tr", count: 1 do
      assert_select "td", text: "192.0.2.7"
      assert_select "td", text: "Preview"
      assert_select "td", text: /\A1 \(2 KB\)\z/
      assert_select "a[href*='session=#{SESSION}']"
    end
    get "/projects/ecookbook/mirror_source", params: { session: SESSION }
    assert_select "table.mirror-source-accesses tbody tr", count: 3
    assert_select "table.mirror-source-accesses td", text: /Documents\s+2 object/
    assert_select "table.mirror-source-accesses", text: /document\.txt/, count: 0
    assert_select "table.mirror-source-accesses tr.mirror-source-refused td", text: "Data not shared"
  end


  def test_access_log_needs_its_own_permission
    @project.enable_module!(:mirror_source)
    log_access("list", object_count: 1, details: JSON.generate("kind" => "documents"))
    Role.find(1).remove_permission!(:view_mirror_source_log)
    log_user("jsmith", "jsmith")
    get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
    assert_select "#mirror-source-form"
    assert_select "table.mirror-source-sessions", count: 0
    get "/projects/ecookbook/mirror_source"
    assert_response :forbidden
  end

  def test_log_viewer_does_not_receive_source_configuration_controls
    @project.enable_module!(:mirror_source)
    log_access("list", object_count: 1, details: JSON.generate("kind" => "documents"))
    Role.find(1).remove_permission!(:manage_mirror_source)
    log_user("jsmith", "jsmith")
    get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
    assert_select "#tab-mirror_source", count: 0
    assert_select "#mirror-source-form", count: 0
    get "/projects/ecookbook/mirror_source"
    assert_response :success
    assert_select "table.mirror-source-sessions"
    assert_select ".contextual a.icon-settings", count: 0
  end

  def test_log_filters_sessions_and_groups_observed_destinations
    @project.enable_module!(:mirror_source)
    log_access("list", object_count: 2, details: JSON.generate("kind" => "documents"))
    log_access("refused", reason: "not_shared")
    log_access("list", session_key: "a" * 32, purpose: "synchronization", remote_ip: "198.51.100.8",
      user_id: 1, object_count: 3, details: JSON.generate("kind" => "documents"))
    log_user("jsmith", "jsmith")

    get "/projects/ecookbook/mirror_source", params: { purpose: "preview" }
    assert_select "table.mirror-source-sessions tbody tr", count: 1 do
      assert_select "td", text: "192.0.2.7"
    end
    get "/projects/ecookbook/mirror_source", params: { refused: "1" }
    assert_select "table.mirror-source-sessions tbody tr", count: 1 do
      assert_select "td", text: "192.0.2.7"
    end
    get "/projects/ecookbook/mirror_source", params: { group_by: "destination" }
    assert_select "table.mirror-source-destinations tbody tr", count: 2
    assert_select "table.mirror-source-destinations td", text: "198.51.100.8"
    get "/projects/ecookbook/mirror_source", params: { group_by: "destination", user_id: 2, remote_ip: "192.0.2.7" }
    assert_select "table.mirror-source-destinations tbody tr", count: 1 do
      assert_select "td", text: "192.0.2.7"
    end
  end

  def test_same_client_session_key_keeps_distinct_accounts_and_addresses
    @project.enable_module!(:mirror_source)
    log_access("list", object_count: 2, details: JSON.generate("kind" => "documents"))
    log_access("refused", user_id: 3, remote_ip: "198.51.100.8", reason: "client_key")
    log_user("jsmith", "jsmith")

    get "/projects/ecookbook/mirror_source"
    assert_select "table.mirror-source-sessions tbody tr", count: 2
    assert_select "a[href*='session=#{SESSION}'][href*='user_id=2'][href*='remote_ip=192.0.2.7']"
    assert_select "a[href*='session=#{SESSION}'][href*='user_id=3'][href*='remote_ip=198.51.100.8']"

    get "/projects/ecookbook/mirror_source", params: { session: SESSION, user_id: 3, remote_ip: "198.51.100.8", purpose: "preview" }
    assert_select "table.mirror-source-accesses tbody tr", count: 1
    assert_select "table.mirror-source-accesses td", text: "198.51.100.8"
  end

  def test_generates_an_application_key_once_and_stores_only_its_digest
    @project.enable_module!(:mirror_source)
    log_user("jsmith", "jsmith")
    # The button sits in the PATCH settings form; it must submit its own POST form.
    get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
    assert_select "#mirror-source-form button[form='mirror-source-client-key-form']"
    assert_select "#mirror-source-form #mirror-source-client-key-form", count: 0
    assert_select "form#mirror-source-client-key-form[action='/projects/ecookbook/mirror_source/client_key'][method=post]" do
      assert_select "input[name=_method]", count: 0
    end
    post "/projects/ecookbook/mirror_source/client_key"
    assert_response :success
    key = css_select("#mirror-source-client-key").first.text
    assert_operator key.length, :>=, 40
    # Rails 5.2 (Redmine 4) adds "private".
    assert_includes response.headers["Cache-Control"].to_s.split(/,\s*/), "no-store"
    setting = @project.reload.mirror_source_setting
    assert setting.client_key_matches?(key)
    refute_includes setting.client_key_digest, key
    get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
    assert_select "body", text: /#{Regexp.escape(key)}/, count: 0
  end

  def test_administrator_switches_mirror_source_in_the_plugin_settings
    log_user("admin", "admin")
    get "/settings/plugin/redmine_mirror"
    assert_select "#settings_source_enabled:not([checked])"
    assert_select "#mirror-source-settings a[href='/admin/mirror/source']"
    # Switched on without any allowed address: kept off.
    post "/settings/plugin/redmine_mirror", params: { settings: { allowed_source_urls: "", user_company_field_id: "", source_enabled: "1", source_log_days: "30" } }
    assert_not RedmineMirror::Source.enabled?
    post "/settings/plugin/redmine_mirror", params: { settings: { allowed_source_urls: "", user_company_field_id: "", source_enabled: "1",
      source_allowed_addresses: "10.0.0.12", source_log_days: "30" } }
    assert RedmineMirror::Source.enabled?
    assert_equal 30, RedmineMirror::Source.retention_days
    post "/settings/plugin/redmine_mirror", params: { settings: { allowed_source_urls: "", user_company_field_id: "", source_enabled: "", source_log_days: "30" } }
    assert_not RedmineMirror::Source.enabled?
  end

  # Only the data this Redmine can serve is offered; projects see only the allowed data,
  # and keep their choice for the rest.
  def test_administrator_chooses_the_data_projects_may_share
    log_user("admin", "admin")
    get "/settings/plugin/redmine_mirror"
    (RedmineMirror::Source.available_kinds - RedmineMirror::Source::EXPLICIT_KINDS).each { |kind| assert_select "#settings_source_kind_#{kind}[checked]" }
    # Personal data, field definitions and repository access are never allowed until
    # the administrator checks them explicitly.
    RedmineMirror::Source::EXPLICIT_KINDS.each { |kind| assert_select "#settings_source_kind_#{kind}:not([checked])" }
    assert_includes RedmineMirror::Source::EXPLICIT_KINDS, "users"
    assert_select "#settings_source_kind_scrum", count: RedmineMirror::Source.scrum_available? ? 1 : 0
    post "/settings/plugin/redmine_mirror", params: { settings: { source_enabled: "1", source_kinds: ["", "news", "queries"] } }
    assert_equal %w[news queries], RedmineMirror::Source.allowed_kinds
    get "/settings/plugin/redmine_mirror"
    assert_select "#settings_source_kind_documents:not([checked])"
    assert_select "#settings_source_kind_news[checked]"

    @project.enable_module!(:mirror_source)
    post "/settings/plugin/redmine_mirror", params: { settings: { source_enabled: "1", source_kinds: ["", "issue_custom_fields", "news", "queries"] } }
    MirrorSourceSetting.create!(project: @project, shared_modules: %w[documents news])
    get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
    assert_select "#mirror-source-share-issue_custom_fields:not([checked])"
    assert_select "#mirror-source-share-documents", count: 0
    assert_select "#mirror-source-share-news[checked]"
    patch "/projects/ecookbook/mirror_source", params: { shared_modules: ["", "queries", "documents"] }
    assert_equal %w[documents queries], @project.reload.mirror_source_setting.shared_modules.sort

    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_kinds" => [""] }) do
      get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
      assert_select "#mirror-source-no-kind"
    end
  end

  # Administration > Mirror > Source: projects, sessions of every project, filters, one session.
  def test_administration_lists_sharing_projects_and_sessions_across_projects
    @project.enable_module!(:mirror_source)
    MirrorSourceSetting.create!(project: @project, shared_modules: %w[documents])
    Project.find(2).enable_module!(:mirror_source)
    log_access("list", object_count: 3)
    log_access("refused", project: Project.find(2), session_key: "a" * 32, reason: "not_shared")
    log_user("admin", "admin")
    get "/admin/mirror/source"
    assert_response :success
    assert_select ".mirror-admin-sidebar a.selected[href='/admin/mirror/source']"
    assert_select ".mirror-admin-sidebar a[href='/admin/mirror']"
    assert_select "#mirror-admin-source-status.warning"
    assert_select "table.mirror-admin-source-projects tbody tr", count: 2
    assert_select "table.mirror-admin-source-projects td", text: "Documents"
    assert_select "table.mirror-source-sessions tbody tr", count: 2
    get "/admin/mirror/source", params: { refused: "1" }
    assert_select "table.mirror-source-sessions tbody tr", count: 1 do
      assert_select "td a[href='/projects/onlinestore']"
    end
    get "/admin/mirror/source", params: { project_id: @project.id }
    assert_select "table.mirror-source-sessions tbody tr", count: 1 do
      assert_select "a[href*='project_id=#{@project.id}'][href*='session=#{SESSION}'][href*='user_id=2']", text: "Details"
    end
    get "/admin/mirror/source", params: { project_id: @project.id, session: SESSION, user_id: 2, remote_ip: "192.0.2.7", purpose: "preview" }
    assert_select "table.mirror-source-accesses tbody tr", count: 1
    assert_select "#mirror-source-no-address", count: 0
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1" }) do
      get "/admin/mirror/source"
      # Switched on without any allowed address: kept off, and the administrator is told why.
      assert_select "#mirror-admin-source-status.warning"
      assert_select "#mirror-source-no-address.warning"
    end
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1", "source_allowed_addresses" => "10.0.0.12" }) do
      get "/admin/mirror/source"
      assert_select "#mirror-admin-source-status.mirror-source-on"
      assert_select "#mirror-source-no-address", count: 0
    end
  end

  def test_only_administrators_see_the_source_page
    log_user("jsmith", "jsmith")
    get "/admin/mirror/source"
    assert_response :forbidden
  end
end
