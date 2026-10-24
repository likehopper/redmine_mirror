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
  end

  def log_access(action, **attributes)
    MirrorSourceAccess.create!({ project: @project, user_id: 2, session_key: SESSION, purpose: "preview", remote_ip: "192.0.2.7",
      action: action, created_at: Time.current }.merge(attributes))
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
    patch "/projects/ecookbook/mirror_source", params: { shared_modules: ["", "documents", "unknown"] }
    assert_redirected_to "/projects/ecookbook/settings/mirror_source"
    assert_equal %w[documents], @project.reload.mirror_source_setting.shared_modules
    patch "/projects/ecookbook/mirror_source", params: { shared_modules: [""] }
    assert_empty @project.reload.mirror_source_setting.shared_modules
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
    log_access("list", object_count: 2, details: JSON.generate("documents" => [{ "id" => 1, "title" => "Test document" }, { "id" => 2, "title" => "An other document" }]))
    log_access("download", object_count: 1, bytes: 2048, details: JSON.generate("attachment" => { "id" => 2, "filename" => "document.txt" }))
    log_access("refused", reason: "not_shared")
    log_user("jsmith", "jsmith")
    get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
    assert_select "table.mirror-source-sessions tbody tr", count: 1 do
      assert_select "td", text: "192.0.2.7"
      assert_select "td", text: "Preview"
      assert_select "td", text: /\A1 \(2 KB\)\z/
      assert_select "a[href*='mirror_source_session=#{SESSION}']"
    end
    get "/projects/ecookbook/settings", params: { tab: "mirror_source", mirror_source_session: SESSION }
    assert_select "table.mirror-source-accesses tbody tr", count: 3
    # What a list returned, under the name of its data.
    assert_select "table.mirror-source-accesses td", text: /\ADocuments\s+Test document \(#1\), An other document \(#2\)\z/
    assert_select "table.mirror-source-accesses td", text: /document\.txt/
    assert_select "table.mirror-source-accesses tr.mirror-source-refused td", text: "Data not shared"
  end

  def test_administrator_switches_mirror_source_in_the_plugin_settings
    log_user("admin", "admin")
    get "/settings/plugin/redmine_mirror"
    assert_select "#settings_source_enabled:not([checked])"
    assert_select "#mirror-source-settings a[href='/admin/mirror/source']"
    post "/settings/plugin/redmine_mirror", params: { settings: { allowed_source_urls: "", user_company_field_id: "", source_enabled: "1", source_log_days: "30" } }
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
    RedmineMirror::Source.available_kinds.each { |kind| assert_select "#settings_source_kind_#{kind}[checked]" }
    assert_select "#settings_source_kind_scrum", count: RedmineMirror::Source.scrum_available? ? 1 : 0
    post "/settings/plugin/redmine_mirror", params: { settings: { source_enabled: "1", source_kinds: ["", "news", "queries"] } }
    assert_equal %w[news queries], RedmineMirror::Source.allowed_kinds
    get "/settings/plugin/redmine_mirror"
    assert_select "#settings_source_kind_documents:not([checked])"
    assert_select "#settings_source_kind_news[checked]"

    @project.enable_module!(:mirror_source)
    MirrorSourceSetting.create!(project: @project, shared_modules: %w[documents news])
    get "/projects/ecookbook/settings", params: { tab: "mirror_source" }
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
      assert_select "a[href='/admin/mirror/source?project_id=#{@project.id}&session=#{SESSION}']", text: "Details"
    end
    get "/admin/mirror/source", params: { project_id: @project.id, session: SESSION }
    assert_select "table.mirror-source-accesses tbody tr", count: 1
    with_settings(plugin_redmine_mirror: { "source_enabled" => "1" }) do
      get "/admin/mirror/source"
      assert_select "#mirror-admin-source-status.mirror-source-on"
    end
  end

  def test_only_administrators_see_the_source_page
    log_user("jsmith", "jsmith")
    get "/admin/mirror/source"
    assert_response :forbidden
  end
end
