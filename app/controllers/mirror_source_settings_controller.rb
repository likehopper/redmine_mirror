# frozen_string_literal: true
# File: redmine_mirror/app/controllers/mirror_source_settings_controller.rb
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
# Save what the project shares with Mirror destinations (Mirror source tab).

class MirrorSourceSettingsController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize

  def update
    setting = @project.mirror_source_setting || @project.build_mirror_source_setting
    setting.shared_modules = params.fetch(:shared_modules, [])
    setting.save!
    flash[:notice] = l(:notice_successful_update)
    redirect_to settings_project_path(@project, tab: "mirror_source")
  end
end
