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
class MirrorControllerTest < ActionController::TestCase
  tests MirrorController
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
  end

  def test_admin_opens_project_configuration
    @request.session[:user_id] = 1
    get :index, params: { project_id: @project.identifier }
    assert_redirected_to project_mirror_settings_path(@project)
  end

  def test_member_without_permission_is_denied
    Role.all.each { |role| role.remove_permission!(:view_mirror) }
    @request.session[:user_id] = 2
    get :index, params: { project_id: @project.identifier }
    assert_response :forbidden
  end

  def test_disabled_module_is_denied
    Role.givable.each { |role| role.add_permission!(:view_mirror) }
    @project.disable_module!(:mirror)
    @request.session[:user_id] = 2
    get :index, params: { project_id: @project.identifier }
    assert_response :forbidden
  end

  def test_allowed_member_sees_catalog
    Role.givable.each { |role| role.add_permission!(:view_mirror) }
    @request.session[:user_id] = 2
    get :index, params: { project_id: @project.identifier }
    assert_response :success
  end

  def test_anonymous_cannot_read_private_project
    @project.update!(is_public: false)
    get :index, params: { project_id: @project.identifier }
    assert_redirected_to signin_path(back_url: "http://test.host/projects/ecookbook/mirror")
  end

  def test_permission_in_one_project_does_not_grant_another
    Role.givable.each { |role| role.add_permission!(:view_mirror) }
    other = Project.create!(name: "Private Mirror", identifier: "private-mirror", is_public: false,
      enabled_module_names: ["mirror"])
    @request.session[:user_id] = 2
    get :index, params: { project_id: other.identifier }
    assert_response :forbidden
  end

end
