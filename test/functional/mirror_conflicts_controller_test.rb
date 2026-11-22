# frozen_string_literal: true
# File: redmine_mirror/test/functional/mirror_conflicts_controller_test.rb
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
class MirrorConflictsControllerTest < ActionController::TestCase
  tests MirrorConflictsController
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules
  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example", source_project_id: 12)
    setting.api_key = "test-key"
    setting.selected_modules = ["issue_tracking"]
    setting.save!
    MirrorMapping.create!(project_id: @project.id, connection_key: "test", module_key: "issue_tracking", source_id: 99, destination_id: 1, source_fingerprint: "a", destination_fingerprint: "b")
    @conflict = @project.mirror_conflicts.create!(connection_key: "test", module_key: "issue_tracking", source_id: 99, destination_id: 1, message: "Local modification detected")
    @request.session[:user_id] = 1
  end
  def test_keep_and_recheck_preserve_mapping_and_fingerprints
    patch :update, params: { project_id: @project.id, id: @conflict.id, resolution: "ignore" }
    assert_redirected_to project_mirror_conflicts_path(@project)
    assert_equal "ignored", @conflict.reload.status
    assert_equal 1, @conflict.resolved_by_id
    assert RedmineMirror::DatabaseStore.new("test", project_id: @project.id).excluded?("issue_tracking", 99)
    assert_not RedmineMirror::DatabaseStore.new("test", project_id: 2).excluded?("issue_tracking", 99)
    assert_equal "b", MirrorMapping.find_by!(connection_key: "test", source_id: 99).destination_fingerprint
    back = project_mirror_conflicts_path(@project, set_filter: 1, f: ["status"], op: { status: "=" }, v: { status: ["ignored"] })
    patch :update, params: { project_id: @project.id, id: @conflict.id, resolution: "recheck", back_url: back }
    assert_redirected_to back
    assert_equal "open", @conflict.reload.status
  end
  def test_cross_project_id_is_not_accessible
    @conflict.update!(project_id: 2)
    patch :update, params: { project_id: @project.id, id: @conflict.id, resolution: "ignore" }
    assert_response :not_found
    assert_equal "open", @conflict.reload.status
  end
  def test_running_job_prevents_resolution
    @project.mirror_sync_runs.create!(status: "queued", trigger: "manual")
    patch :update, params: { project_id: @project.id, id: @conflict.id, resolution: "ignore" }
    assert flash[:error]
    assert_equal "open", @conflict.reload.status
  end
  def test_list_shows_open_conflicts_with_their_dates_and_follows_filters_and_groups
    @conflict.update_columns(created_at: Time.utc(2026, 11, 1, 10), checked_at: Time.utc(2026, 11, 20, 10))
    @project.mirror_conflicts.create!(connection_key: "test", module_key: "issue_tracking", source_id: 98, destination_id: 2, message: "Local modification detected", status: "ignored", resolved_by_id: 1)
    @project.mirror_conflicts.create!(connection_key: "test", module_key: "issue_tracking", source_id: 97, message: "Local modification detected").update_columns(project_id: 2)
    get :index, params: { project_id: @project.id }
    assert_response :success
    assert_select "#mirror-conflicts tbody tr.hascontextmenu", count: 1
    assert_select "#mirror-conflicts thead th", text: "Detected on"
    assert_select "#mirror-conflicts thead th", text: "Last checked"
    assert_select "#mirror-conflicts td.created_at", text: /11\/01\/2026/
    assert_select "#mirror-conflicts input[name='ids[]'][value='#{@conflict.id}']"
    get :index, params: { project_id: @project.id, set_filter: 1, f: [""], group_by: "status", c: %w[module_key source_id status resolved_by], sort: "source_id" }
    assert_select "#mirror-conflicts tbody tr.hascontextmenu", count: 2
    assert_select "#mirror-conflicts tr.group span.name", text: "Open"
    assert_select "#mirror-conflicts tr.group span.count", text: "1", count: 2
    assert_select "#mirror-conflicts td.resolved_by a", text: User.find(1).name
    get :index, params: { project_id: @project.id, set_filter: 1, f: ["resolved_by_id"], op: { resolved_by_id: "=" }, v: { resolved_by_id: ["1"] } }
    assert_select "#mirror-conflicts tbody tr.hascontextmenu", count: 1
    assert_select "#mirror-conflicts td.source_id", text: "98"
  end

  def test_context_menu_offers_the_three_resolutions_for_the_selection
    other = @project.mirror_conflicts.create!(connection_key: "test", module_key: "issue_tracking", source_id: 98, message: "Local modification detected")
    get :context_menu, params: { project_id: @project.id, ids: [@conflict.id, other.id] }
    assert_response :success
    assert_select "a[data-method=patch]", count: 3
    assert_select "a[href*='resolution=source'][data-confirm]", text: "Take the source version"
    get :context_menu, params: { project_id: @project.id, ids: [999_999] }
    assert_response :not_found
  end

  # Without a correspondence there is nothing local to keep: the other conflicts are still updated.
  def test_bulk_resolution_updates_every_selected_conflict
    other = @project.mirror_conflicts.create!(connection_key: "test", module_key: "issue_tracking", source_id: 98, message: "Local modification detected")
    patch :bulk_update, params: { project_id: @project.id, ids: [@conflict.id, other.id], resolution: "source" }
    assert_redirected_to project_mirror_conflicts_path(@project)
    assert_equal %w[source source], [@conflict.reload.status, other.reload.status]
    assert RedmineMirror::DatabaseStore.new("test", project_id: @project.id).source_chosen?("issue_tracking", 98)
    assert_equal "b", MirrorMapping.find_by!(connection_key: "test", source_id: 99).destination_fingerprint
    patch :bulk_update, params: { project_id: @project.id, ids: [@conflict.id, other.id], resolution: "ignore" }
    assert_equal %w[ignored source], [@conflict.reload.status, other.reload.status]
    assert flash[:warning]
    RedmineMirror::DatabaseStore.new("test", project_id: @project.id).resolve_conflict("issue_tracking", 98)
    assert_equal "resolved", other.reload.status
  end

  def test_viewer_sees_the_list_without_selection_or_resolution
    Role.all.each { |role| %i[run_mirror manage_mirror select_project_modules].each { |permission| role.remove_permission!(permission) }; role.add_permission!(:view_mirror) }
    @request.session[:user_id] = 2
    get :index, params: { project_id: @project.id }
    assert_response :success
    assert_select "#mirror-conflicts tbody tr", count: 1
    assert_select "#mirror-conflicts input[name='ids[]']", count: 0
    patch :bulk_update, params: { project_id: @project.id, ids: [@conflict.id], resolution: "source" }
    assert_response :forbidden
    assert_equal "open", @conflict.reload.status
  end

  def test_user_without_permission_is_forbidden
    Role.all.each { |role| %i[run_mirror manage_mirror select_project_modules].each { |permission| role.remove_permission!(permission) } }
    @request.session[:user_id] = 2
    patch :update, params: { project_id: @project.id, id: @conflict.id, resolution: "ignore" }
    assert_response :forbidden
    assert_equal "open", @conflict.reload.status
  end
end
