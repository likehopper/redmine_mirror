# frozen_string_literal: true
# File: redmine_mirror/app/controllers/mirror_controller.rb
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
# Route the project Mirror menu and resolve authorized remote-to-local object links.

class MirrorController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize

  def index
    if User.current.allowed_to?(:manage_mirror, @project)
      redirect_to project_mirror_settings_path(@project)
      return
    end
    @modules = RedmineMirror::REGISTRY.keys
  end
end
