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
# List the project's conflicts as a Redmine query and resolve one or several of them:
# keep the local object, choose the source version, or recheck after a correction.

class MirrorConflictsController < ApplicationController
  include RedmineMirror::PlainFlash
  include RedmineMirror::Authorization
  helper :queries
  include QueriesHelper
  helper :context_menus
  helper MirrorHelper
  menu_item :mirror
  before_action :find_project_by_project_id
  before_action -> { authorize_mirror(:view) }, only: :index
  before_action -> { authorize_mirror(:run) }, except: :index

  # Resolution chosen by the user => status stored on the conflict.
  RESOLUTIONS = { "ignore" => "ignored", "source" => "source", "recheck" => "open" }.freeze

  def index
    @setting = @project.mirror_project_setting
    return render_404 unless @setting
    retrieve_query(MirrorConflictQuery, false)
    return unless @query.valid?
    @conflict_count = @query.base_scope.count
    @conflict_pages = Paginator.new(@conflict_count, per_page_option, params["page"])
    @conflicts = @query.results(offset: @conflict_pages.offset, limit: @conflict_pages.per_page)
  rescue Query::StatementInvalid
    render_error status: 500
  end

  def context_menu
    @conflicts = @project.mirror_conflicts.where(id: params[:ids]).to_a
    return render_404 if @conflicts.empty?
    @back = params[:back_url]
    render layout: false
  end

  def update
    resolve([params[:id]])
  end

  def bulk_update
    resolve(Array(params[:ids]))
  end

  private

  # Resolve under the same project lock as enqueueing so a running import cannot race
  # with a changed decision. No resolution resets fingerprints or writes local data:
  # the source version is written by the next run, through the usual import path.
  def resolve(ids)
    setting = @project.mirror_project_setting
    return render_404 unless setting
    status = RESOLUTIONS[params[:resolution]]
    count = 0
    setting.with_lock do
      raise RedmineMirror::Error, "Synchronization already queued or running" if setting.running_run_id || @project.mirror_sync_runs.where(status: %w[queued running]).exists?
      raise RedmineMirror::Error, "Invalid conflict resolution" unless status
      conflicts = @project.mirror_conflicts.where(id: ids).to_a
      raise ActiveRecord::RecordNotFound if conflicts.empty? || conflicts.size != ids.uniq.size
      conflicts.each do |conflict|
        # Keeping a local object needs its correspondence: without it there is nothing local to keep.
        next if status == "ignored" && !keepable?(conflict)
        conflict.update!(status: status, resolved_by: User.current)
        count += 1
      end
    end
    if count == ids.size
      flash[:notice] = l(:notice_successful_update)
    else
      flash[:warning] = l(:text_mirror_conflicts_partly_updated, count: count, total: ids.size)
    end
    redirect_back_or_default project_mirror_conflicts_path(@project)
  rescue ActiveRecord::RecordNotFound
    render_404
  rescue RedmineMirror::Error => error
    flash[:error] = error.message
    redirect_back_or_default project_mirror_conflicts_path(@project)
  end

  def keepable?(conflict)
    conflict.destination_id && MirrorMapping.exists?(project_id: @project.id, connection_key: conflict.connection_key,
      module_key: conflict.module_key, source_id: conflict.source_id, destination_id: conflict.destination_id)
  end
end
