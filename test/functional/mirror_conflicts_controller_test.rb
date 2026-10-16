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
    assert_redirected_to project_mirror_settings_path(@project, tab: "conflicts")
    assert_equal "ignored", @conflict.reload.status
    assert_equal 1, @conflict.resolved_by_id
    assert RedmineMirror::DatabaseStore.new("test", project_id: @project.id).excluded?("issue_tracking", 99)
    assert_not RedmineMirror::DatabaseStore.new("test", project_id: 2).excluded?("issue_tracking", 99)
    assert_equal "b", MirrorMapping.find_by!(connection_key: "test", source_id: 99).destination_fingerprint
    patch :update, params: { project_id: @project.id, id: @conflict.id, resolution: "recheck" }
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
  def test_user_without_permission_is_forbidden
    Role.all.each { |role| role.remove_permission!(:manage_mirror) }
    @request.session[:user_id] = 2
    patch :update, params: { project_id: @project.id, id: @conflict.id, resolution: "ignore" }
    assert_response :forbidden
    assert_equal "open", @conflict.reload.status
  end
end
