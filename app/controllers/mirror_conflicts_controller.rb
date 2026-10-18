# frozen_string_literal: true
# File: redmine_mirror/app/controllers/mirror_conflicts_controller.rb
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
# Exclude or recheck scoped conflicts without resetting fingerprints or changing local data.

class MirrorConflictsController < ApplicationController
  include RedmineMirror::Authorization
  before_action :find_project_by_project_id
  before_action -> { authorize_mirror(:run) }

  def update
    setting = @project.mirror_project_setting
    return render_404 unless setting
    # Resolve under the same project lock as enqueueing so a running import cannot
    # race with a changed exclusion decision. Rechecking retains all fingerprints.
    setting.with_lock do
      raise RedmineMirror::Error, "Synchronization already queued or running" if setting.running_run_id || @project.mirror_sync_runs.where(status: %w[queued running]).exists?
      conflict = @project.mirror_conflicts.find(params[:id])
      raise RedmineMirror::Error, "Invalid conflict resolution" unless %w[ignore recheck].include?(params[:resolution])
      if params[:resolution] == "ignore"
        raise RedmineMirror::Error, "Missing local correspondence" unless MirrorMapping.exists?(project_id: @project.id, connection_key: conflict.connection_key, module_key: conflict.module_key, source_id: conflict.source_id, destination_id: conflict.destination_id)
      end
      conflict.update!(status: params[:resolution] == "ignore" ? "ignored" : "open", resolved_by: User.current)
    end
    flash[:notice] = l(:notice_successful_update)
    redirect_to project_mirror_path(@project, tab: "conflicts")
  rescue ActiveRecord::RecordNotFound
    render_404
  rescue RedmineMirror::Error => error
    flash[:error] = error.message
    redirect_to project_mirror_path(@project, tab: "conflicts")
  end
end
