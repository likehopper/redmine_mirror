# frozen_string_literal: true
# File: redmine_mirror/app/controllers/mirror_synchronizations_controller.rb
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
# Enqueue authorized project work and expose filtered execution diagnostics.

class MirrorSynchronizationsController < ApplicationController
  include RedmineMirror::Authorization
  helper MirrorHelper
  before_action :find_project_by_project_id
  before_action -> { authorize_mirror(:view) }, only: :show
  before_action -> { authorize_mirror(:run) }, only: [:create, :cancel]
  before_action -> { authorize_mirror(:manage) }, only: :update
  before_action :load_setting

  def update
    input = params.require(:schedule).permit(:enabled, :interval_minutes, :on_error, :source_wins)
    interval = Integer(input.fetch(:interval_minutes))
    raise RedmineMirror::Error, "Invalid synchronization interval" unless MirrorProjectSetting::SYNC_INTERVALS.include?(interval)
    @setting.update!(auto_sync_enabled: input[:enabled] == "1", sync_interval_minutes: interval,
      next_sync_at: input[:enabled] == "1" ? Time.current + interval.minutes : nil,
      on_error: input[:on_error].presence || @setting.on_error, source_wins: input[:source_wins] == "1")
    flash[:notice] = l(:notice_successful_update)
    redirect_to settings_project_path(@project, tab: "mirror", mirror_tab: "schedule")
  rescue RedmineMirror::Error, ActiveRecord::RecordInvalid, ArgumentError, KeyError
    flash[:error] = l(:text_mirror_invalid_schedule)
    redirect_to settings_project_path(@project, tab: "mirror", mirror_tab: "schedule")
  end

  def create
    raise RedmineMirror::Error, "Invalid synchronization mode" unless %w[preview apply].include?(params[:mode])
    run = RedmineMirror::Synchronization.enqueue(@setting, apply: params[:mode] == "apply", trigger: "manual", user: User.current,
      confirm_deletions: params[:confirm_deletions] == "1")
    flash[:notice] = l(:text_mirror_sync_queued)
    redirect_to project_mirror_run_path(@project, run)
  rescue RedmineMirror::Error => error
    flash[:error] = error.message
    redirect_to project_mirror_path(@project)
  end

  def cancel
    run = @project.mirror_sync_runs.find_by(id: params[:id])
    return render_404 unless run
    RedmineMirror::Synchronization.cancel(run)
    flash[:notice] = l(:text_mirror_run_cancelled)
    redirect_to project_mirror_path(@project)
  rescue RedmineMirror::Error => error
    flash[:error] = error.message
    redirect_to project_mirror_path(@project)
  end

  def show
    @run = @project.mirror_sync_runs.find_by(id: params[:id])
    return render_404 unless @run
    @source_url = @run.source_url.presence || @setting.source_url
    key = @run.connection_key.presence || mirror_connection_key
    @object_mappings = key ? MirrorMapping.where(connection_key: key).to_a.to_h { |row| [[row.module_key, row.source_id], row.destination_id] } : {}
    @events = @run.log_events
    # Review summary: actions per module, and objects per special case to check.
    @action_counts = @events.group_by { |event| event["module"] }.transform_values { |rows| rows.group_by { |event| event["action"] }.transform_values(&:size) }
    @flag_counts = @events.flat_map { |event| Array(event["flags"]) }.tally
    @warning_counts = @events.flat_map { |event| Array(event["warnings"]) }.tally.sort_by { |_, count| -count }
    @error_counts = @events.select { |event| event["action"] == "error" }.group_by { |event| mirror_cause(event["reason"]) }.transform_values(&:size).sort_by { |_, count| -count }
    @events = @events.select { |event| event["module"] == params[:module_key] } if params[:module_key].present?
    if params[:flag].present?
      @events = @events.select { |event| params[:flag] == "any" ? Array(event["flags"]).any? : Array(event["flags"]).include?(params[:flag]) }
    end
    @events = @events.select { |event| event["action"] == params[:action_filter] } if params[:action_filter].present?
    @events = @events.select { |event| mirror_cause(event["reason"]) == params[:reason] } if params[:reason].present?
    @events = @events.select { |event| Array(event["warnings"]).include?(params[:warning]) } if params[:warning].present?
    @events = @events.select { |event| event["source_id"].to_s == params[:source_id] } if params[:source_id].present?
    @event_count = @events.size
    @event_pages = Paginator.new(@event_count, 50, params[:page])
    @events = @events.slice(@event_pages.offset, 50) || []
  end

  private

  # Causes that differ only by the source object ID are one cause.
  def mirror_cause(reason)
    reason.to_s.sub(/ for (\w+) source ID \d+\z/, ' for \\1')
  end

  def mirror_connection_key
    destination = ENV["MIRROR_DESTINATION_URL"]
    return nil if destination.blank?
    Digest::SHA256.hexdigest(JSON.generate([@setting.source_url.sub(%r{/+\z}, ""), @setting.source_project_id, destination.sub(%r{/+\z}, ""), @project.id]))
  end

  def load_setting
    @setting = @project.mirror_project_setting
    render_404 unless @setting
  end
end
