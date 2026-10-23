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
# The project's Mirror page: overview and setup steps, execution history, conflicts,
# pending links and imported objects. The configuration is in the project settings.

class MirrorController < ApplicationController
  include RedmineMirror::Authorization
  helper MirrorHelper
  before_action :find_project_by_project_id
  before_action -> { authorize_mirror(:view) }
  before_action :require_migrated_schema

  TABS = %w[overview history conflicts pending objects].freeze

  def index
    @setting = @project.mirror_project_setting
    @tab = @setting && TABS.include?(params[:tab]) ? params[:tab] : "overview"
    @open_conflict_count = @project.mirror_conflicts.where(status: "open").count
    @pending_parent_count = @project.mirror_pending_parents.count
    @pending_count = MirrorPendingRelation.where(project_id: @project.id).count
    send("prepare_#{@tab}") if @setting && @tab != "overview"
  end

  private

  def require_migrated_schema
    render_error message: l(:text_mirror_pending_migrations), status: 503 unless MirrorProjectSetting.schema_current?
  end

  # Open conflicts are the ones to handle: the tab lists them unless another status is chosen.
  def prepare_conflicts
    @conflict_status = %w[open ignored resolved all].include?(params[:conflict_status]) ? params[:conflict_status] : "open"
    @conflicts = @project.mirror_conflicts.order(updated_at: :desc)
    @conflicts = @conflicts.where(status: @conflict_status) unless @conflict_status == "all"
    @conflict_count = @conflicts.count
    @conflict_pages = Paginator.new(@conflict_count, 25, params[:page])
    @conflicts = @conflicts.limit(25).offset(@conflict_pages.offset)
  end

  # Date filters use the viewer’s time zone and include the whole final day.
  def prepare_history
    @runs = @project.mirror_sync_runs.order(id: :desc)
    @runs = @runs.where(status: params[:status]) if MirrorSyncRun::STATUSES.include?(params[:status])
    @runs = @runs.where(trigger: params[:trigger]) if MirrorSyncRun::TRIGGERS.include?(params[:trigger])
    @runs = @runs.where(apply: params[:mode] == "apply") if %w[apply preview].include?(params[:mode])
    %w[from to].each do |boundary|
      next if params[boundary].blank?
      begin
        date = Date.iso8601(params[boundary])
        zone = User.current.time_zone || Time.zone
        time = zone.local(date.year, date.month, date.day)
        @runs = boundary == "from" ? @runs.where("created_at >= ?", time) : @runs.where("created_at < ?", time + 1.day)
      rescue ArgumentError
        flash.now[:error] = l(:text_mirror_invalid_configuration)
        @runs = @runs.none
      end
    end
    @runs = @runs.for_module(params[:module_key]) if RedmineMirror::REGISTRY.keys.include?(params[:module_key])
    @run_count = @runs.count
    @run_pages = Paginator.new(@run_count, 25, params[:page])
    @runs = @runs.limit(25).offset(@run_pages.offset)
  end

  def prepare_objects
    @objects = @setting.object_mappings
    @objects = @objects.where(module_key: params[:module_key]) if params[:module_key].present?
    @objects = @objects.where(source_id: params[:source_id]) if params[:source_id].present?
    @objects = @objects.where(destination_id: params[:destination_id]) if params[:destination_id].present?
    @object_count = @objects.count
    @object_pages = Paginator.new(@object_count, 50, params[:page])
    @objects = @objects.order(:module_key, :source_id).limit(50).offset(@object_pages.offset)
  end

  # Parents and relations share the tab; the parents have their own page parameter.
  def prepare_pending
    @parents = @project.mirror_pending_parents.order(:source_id)
    @parents = @parents.where(status: params[:pending_status]) if %w[pending blocked].include?(params[:pending_status])
    @parent_count = @parents.count
    @parent_pages = Paginator.new(@parent_count, 50, params[:parents_page], :parents_page)
    @parents = @parents.limit(50).offset(@parent_pages.offset)
    @pending = MirrorPendingRelation.where(project_id: @project.id)
    @pending = @pending.where(status: params[:pending_status]) if %w[pending blocked].include?(params[:pending_status])
    @pending_total = @pending.count
    @pending_pages = Paginator.new(@pending_total, 50, params[:page])
    @pending = @pending.order(:source_id).limit(50).offset(@pending_pages.offset)
  end
end
