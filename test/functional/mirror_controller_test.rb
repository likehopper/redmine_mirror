# frozen_string_literal: true
# File: redmine_mirror/test/functional/mirror_controller_test.rb
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
require "minitest/mock"
class MirrorControllerTest < ActionController::TestCase
  tests MirrorController
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules, :trackers, :projects_trackers, :issue_statuses, :enumerations

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
  end

  def configure
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 12,
      source_project_identifier: "legacy")
    @setting.selected_modules = %w[issue_tracking time_tracking]
    @setting.api_key = "private-api-key"
    @setting.source_catalog = { "tracker" => { "1" => "Bug" }, "status" => { "1" => "Open" },
      "priority" => { "1" => "Normal" }, "user" => { "7" => "Remote Alice" }, "activity" => { "9" => "Development" } }
    @setting.catalog_status = "ready"
    @setting.save!
    @setting
  end

  # Configuring follows manage_mirror and the right to enable the project's modules.
  def revoke(*permissions)
    Role.all.each { |role| permissions.each { |permission| role.remove_permission!(permission) } }
  end

  def grant(*permissions)
    Role.givable.each { |role| permissions.each { |permission| role.add_permission!(permission) } }
  end

  def test_unconfigured_project_shows_getting_started_to_managers
    @request.session[:user_id] = 1
    get :index, params: { project_id: @project.identifier }
    assert_response :success
    assert_select "#mirror-not-configured"
    assert_select "#mirror-step-connection.mirror-step-current a[href='/projects/ecookbook/settings/mirror']"
    assert_select ".contextual a[href='/projects/ecookbook/settings/mirror']"
    assert_select "#mirror-page-tabs", count: 0
  end

  def test_unconfigured_project_tells_viewers_who_configures_it
    revoke(:manage_mirror, :select_project_modules)
    grant(:view_mirror)
    @request.session[:user_id] = 2
    get :index, params: { project_id: @project.identifier }
    assert_response :success
    assert_select "#mirror-setup", count: 0
    assert_select "p", text: /sets it up in the project settings/
  end

  # Getting started points to the next step: here, the references left to map.
  def test_overview_points_to_the_references_left_to_map
    configure
    @request.session[:user_id] = 1
    get :index, params: { project_id: @project.identifier }
    assert_response :success
    assert_select "#mirror-step-connection.mirror-step-done"
    assert_select "#mirror-step-references.mirror-step-done"
    assert_select "#mirror-step-mappings.mirror-step-current a[href='/projects/ecookbook/settings/mirror?mirror_tab=users']"
    assert_select "#mirror-step-mappings .mirror-step-detail", text: "Users 1, Issues 3, Time tracking 1"
    assert_select "#mirror-source-summary a[href='https://source.example/redmine/projects/legacy']"
    assert_select "#mirror-actions form", count: 2
    assert_no_match "private-api-key", response.body
  end

  def test_getting_started_disappears_after_a_first_synchronization
    configure
    { "tracker" => [1, 1], "status" => [1, 1], "priority" => [1, IssuePriority.first.id], "user" => [7, 2], "activity" => [9, TimeEntryActivity.first.id] }.each do |kind, (source, local)|
      @project.mirror_reference_mappings.create!(reference_type: kind, source_id: source, destination_id: local, mode: "existing")
    end
    @project.mirror_sync_runs.create!(trigger: "manual", status: "succeeded", apply: true)
    @request.session[:user_id] = 1
    get :index, params: { project_id: @project.identifier }
    assert_select "#mirror-setup", count: 0
    assert_select "#mirror-recent-runs tbody tr", count: 1
  end

  def test_viewer_sees_status_without_actions_or_configuration
    configure
    revoke(:manage_mirror, :run_mirror, :select_project_modules)
    grant(:view_mirror)
    @request.session[:user_id] = 2
    get :index, params: { project_id: @project.identifier }
    assert_response :success
    assert_select "#mirror-sync-summary"
    assert_select "#mirror-actions", count: 0
    assert_select ".contextual a.icon-settings", count: 0
  end

  def test_runner_can_launch_but_not_configure
    configure
    revoke(:manage_mirror, :select_project_modules)
    grant(:run_mirror)
    @request.session[:user_id] = 2
    get :index, params: { project_id: @project.identifier }
    assert_select "#mirror-actions form", count: 2
    assert_select ".contextual a.icon-settings", count: 0
  end

  def test_module_manager_configures_without_the_mirror_permission
    revoke(:view_mirror, :run_mirror, :manage_mirror)
    @request.session[:user_id] = 2
    get :index, params: { project_id: @project.identifier }
    assert_response :success
    assert_select ".contextual a[href='/projects/ecookbook/settings/mirror']"
  end

  def test_member_without_permission_is_denied
    revoke(:view_mirror, :run_mirror, :manage_mirror, :select_project_modules)
    @request.session[:user_id] = 2
    get :index, params: { project_id: @project.identifier }
    assert_response :forbidden
  end

  def test_disabled_module_is_denied
    grant(:view_mirror)
    @project.disable_module!(:mirror)
    @request.session[:user_id] = 2
    get :index, params: { project_id: @project.identifier }
    assert_response :forbidden
  end

  def test_anonymous_cannot_read_private_project
    @project.update!(is_public: false)
    get :index, params: { project_id: @project.identifier }
    assert_redirected_to signin_path(back_url: "http://test.host/projects/ecookbook/mirror")
  end

  def test_permission_in_one_project_does_not_grant_another
    grant(:view_mirror)
    other = Project.create!(name: "Private Mirror", identifier: "private-mirror", is_public: false,
      enabled_module_names: ["mirror"])
    @request.session[:user_id] = 2
    get :index, params: { project_id: other.identifier }
    assert_response :forbidden
  end

  def test_pending_relations_are_project_scoped_and_filtered
    configure.update!(selected_modules: ["issue_relations"])
    MirrorMapping.create!(project_id: @project.id, connection_key: "test", module_key: "issue_tracking", source_id: 1, destination_id: 34, source_fingerprint: "a", destination_fingerprint: "b")
    values = { connection_key: "test", local_issue_id: 34, remote_issue_id: 56,
      relation_type: "relates", checked_at: Time.current, reason: "Target not imported" }
    MirrorPendingRelation.create!(values.merge(project_id: @project.id, source_id: 10, status: "pending"))
    MirrorPendingRelation.create!(values.merge(project_id: @project.id, source_id: 11, status: "blocked"))
    MirrorPendingRelation.create!(values.merge(project_id: 2, source_id: 999, status: "pending"))
    @request.session[:user_id] = 1
    get :index, params: { project_id: @project.id, tab: "pending", pending_status: "pending" }
    assert_response :success
    assert_select "#mirror-pending-relations tbody tr", count: 1
    assert_select '#mirror-pending-relations a[href="/issues/34"]'
    assert_select '#mirror-pending-relations a[href="https://source.example/redmine/issues/1#relations"]', text: "10"
    assert_select '#mirror-pending-relations a[href="https://source.example/redmine/issues/1"]', text: "1"
    assert_select "#mirror-pending-relations th", text: "Source issue"
    assert_select '#mirror-pending-relations a[href="https://source.example/redmine/issues/56"]'
    assert_select "#mirror-pending-relations", text: /Target not imported/
    assert_select "#mirror-pending-relations", text: /999/, count: 0
    get :index, params: { project_id: @project.id }
    assert_select '#mirror-attention a[href*="tab=pending"]', text: /2 pending or blocked relations/
  end

  def test_pending_parents_are_filtered_and_project_scoped
    configure.update!(selected_modules: ["issue_hierarchy"])
    values = { connection_key: "test", local_issue_id: 34, remote_parent_id: 56, reason: "Parent missing", checked_at: Time.current }
    @project.mirror_pending_parents.create!(values.merge(source_id: 10, status: "pending"))
    @project.mirror_pending_parents.create!(values.merge(source_id: 11, status: "blocked"))
    MirrorPendingParent.create!(values.merge(project_id: 2, source_id: 999, status: "pending"))
    @request.session[:user_id] = 1
    get :index, params: { project_id: @project.id, tab: "pending", pending_status: "pending" }
    assert_response :success
    assert_select "#mirror-pending-parents tbody tr", count: 1
    assert_select '#mirror-pending-parents a[href="https://source.example/redmine/issues/10"]'
    assert_select '#mirror-pending-parents a[href="/issues/34"]'
    assert_select '#mirror-pending-parents a[href="https://source.example/redmine/issues/56"]'
    assert_select "#mirror-pending-parents", text: /999/, count: 0
    get :index, params: { project_id: @project.id }
    assert_select '#mirror-attention a[href*="tab=pending"]', text: "2 pending or blocked parents"
  end

  def test_history_filters_and_overview_are_separate
    configure
    success = @project.mirror_sync_runs.create!(trigger: "manual", status: "succeeded", apply: true,
      module_totals: JSON.generate("time_tracking" => 13), started_at: 1.minute.ago, finished_at: Time.current)
    @project.mirror_sync_runs.create!(trigger: "automatic", status: "failed", apply: false)
    @request.session[:user_id] = 1
    get :index, params: { project_id: @project.identifier, tab: "history", status: "succeeded", mode: "apply", trigger: "manual", module_key: "time_tracking" }
    assert_response :success
    assert_select "#mirror-history tbody tr", count: 1
    assert_select "#mirror-history a", text: success.id.to_s
    get :index, params: { project_id: @project.identifier }
    assert_response :success
    assert_select "#mirror-sync-summary"
    assert_select "#mirror-history", count: 0
  end

  def test_history_rejects_invalid_date_and_paginates
    configure
    26.times { @project.mirror_sync_runs.create!(trigger: "manual") }
    @request.session[:user_id] = 1
    get :index, params: { project_id: @project.identifier, tab: "history" }
    assert_select "#mirror-history tbody tr", count: 25
    get :index, params: { project_id: @project.identifier, tab: "history", page: 2 }
    assert_select "#mirror-history tbody tr", count: 1
    get :index, params: { project_id: @project.identifier, tab: "history", from: "invalid" }
    assert_select "#mirror-history tbody tr", count: 0
  end

  def test_object_mapping_table_is_project_scoped_and_links_both_ids
    configure
    MirrorMapping.create!(project_id: @project.id, connection_key: "a" * 64, module_key: "issue_tracking",
      source_id: 12, destination_id: 34, source_fingerprint: "a", destination_fingerprint: "b")
    MirrorMapping.create!(project_id: 2, connection_key: "b" * 64, module_key: "issue_tracking",
      source_id: 99, destination_id: 99, source_fingerprint: "a", destination_fingerprint: "b")
    @request.session[:user_id] = 1
    get :index, params: { project_id: @project.identifier, tab: "objects" }
    assert_response :success
    assert_select "#mirror-object-mappings tbody tr", count: 1
    assert_select 'a[href="https://source.example/redmine/issues/12"]', text: "12"
    assert_select 'a[href="/issues/34"]', text: "34"
  end

  def test_open_conflicts_are_counted_in_the_tab
    configure
    @project.mirror_conflicts.create!(connection_key: "test", module_key: "issue_tracking", source_id: 99, destination_id: 1, message: "Local modification detected")
    @request.session[:user_id] = 1
    get :index, params: { project_id: @project.identifier }
    assert_select "#mirror-page-tabs a[href*='tab=conflicts']", text: "Conflicts (1)"
    assert_select "#mirror-attention a", text: "1 open conflicts"
  end

  def test_conflicts_tab_lists_open_conflicts_by_default
    configure
    values = { connection_key: "test", module_key: "issue_tracking", destination_id: 1, message: "Local modification detected" }
    @project.mirror_conflicts.create!(values.merge(source_id: 98))
    @project.mirror_conflicts.create!(values.merge(source_id: 99, status: "ignored"))
    @request.session[:user_id] = 1
    get :index, params: { project_id: @project.identifier, tab: "conflicts" }
    assert_select "#mirror-conflicts tbody tr", count: 1
    assert_select "select#conflict_status option[selected]", text: "Open"
    assert_select "#mirror-conflicts input[name=conflict_status][value=open]"
    get :index, params: { project_id: @project.identifier, tab: "conflicts", conflict_status: "all" }
    assert_select "#mirror-conflicts tbody tr", count: 2
    get :index, params: { project_id: @project.identifier, tab: "conflicts", conflict_status: "resolved" }
    assert_select "#mirror-conflicts tbody tr", count: 0
    assert_select "p.nodata"
  end

  def test_pending_migrations_are_explained_instead_of_failing
    MirrorProjectSetting.stub(:column_names, MirrorProjectSetting.column_names - ["source_text_format"]) do
      @request.session[:user_id] = 1
      get :index, params: { project_id: @project.identifier }
    end
    assert_response 503
    assert_includes response.body, "redmine:plugins:migrate"
  end
end
