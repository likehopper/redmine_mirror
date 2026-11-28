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
  include RedmineMirror::PlainFlash
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
    # The simulation is withdrawn from the pages; operators keep it through rake.
    raise RedmineMirror::Error, "Invalid synchronization mode" unless params[:mode] == "apply"
    run = RedmineMirror::Synchronization.enqueue(@setting, apply: true,
      trigger: params[:recover_missing_files] == "1" ? "recovery" : "manual", user: User.current,
      confirm_deletions: params[:confirm_deletions] == "1", force_full: params[:force_full] == "1")
    flash[:notice] = l(:text_mirror_sync_queued)
    redirect_to project_mirror_run_path(@project, run)
  rescue RedmineMirror::Error => error
    flash[:error] = error.message
    redirect_to project_mirror_path(@project)
  end

  def cancel
    run = @project.mirror_sync_runs.find_by(id: params[:id])
    return render_404 unless run
    outcome = RedmineMirror::Synchronization.cancel(run, user: User.current)
    flash[:notice] = l(outcome == :stopping ? :text_mirror_run_stop_requested : :text_mirror_run_cancelled)
    # A stopping execution is followed on its own page until it ends.
    redirect_to outcome == :stopping ? project_mirror_run_path(@project, run) : project_mirror_path(@project)
  rescue RedmineMirror::Error => error
    flash[:error] = error.message
    redirect_to project_mirror_path(@project)
  end

  def show
    @run = @project.mirror_sync_runs.find_by(id: params[:id])
    return render_404 unless @run
    @source_url = @run.source_url.presence || @setting.source_url
    key = @run.connection_key.presence || mirror_connection_key
    entries = @run.log_entries
    # Review summary: actions per module, and objects per special case to check.
    @action_counts = {}
    entries.group(:module_key, :action).count.each { |(module_key, action), count| (@action_counts[module_key] ||= {})[action] = count }
    @module_keys = @action_counts.keys
    # Flags, warnings and error details live in data: only rows carrying some are read.
    @flag_counts = Hash.new(0)
    warning_counts = Hash.new(0)
    flag_ids = []
    warning_ids = []
    entries.where.not(data: nil).select(:id, :data).find_each do |entry|
      data = JSON.parse(entry.data)
      flags = Array(data["flags"])
      warnings = Array(data["warnings"])
      flags.each { |flag| @flag_counts[flag] += 1 }
      warnings.each { |warning| warning_counts[warning] += 1 }
      flag_ids << entry.id if params[:flag].present? && (params[:flag] == "any" ? flags.any? : flags.include?(params[:flag]))
      warning_ids << entry.id if params[:warning].present? && warnings.include?(params[:warning])
    end
    @warning_counts = warning_counts.sort_by { |_, count| -count }
    # Errors grouped by cause, the largest first, each explained with its fix (Diagnosis).
    errors = entries.where(action: "error")
    @error_groups = RedmineMirror::Diagnosis.groups(errors.find_each.lazy.map(&:to_event))
    scope = entries
    scope = scope.where(module_key: params[:module_key]) if params[:module_key].present?
    scope = scope.where(action: params[:action_filter]) if params[:action_filter].present?
    scope = scope.where(source_id: params[:source_id].to_s) if params[:source_id].present?
    if params[:flag].present?
      scope = scope.where(id: flag_ids)
    end
    scope = scope.where(id: warning_ids) if params[:warning].present?
    if params[:reason].present?
      ids = errors.find_each.each_with_object([]) do |entry, matching|
        matching << entry.id if RedmineMirror::Diagnosis.group_key(entry.to_event) == params[:reason]
      end
      scope = scope.where(id: ids)
    end
    @event_count = scope.count
    @event_pages = Paginator.new(@event_count, 50, params[:page])
    # Grouped rows are ordered by their group first, as in Redmine's issue list.
    @group_by = params[:group_by].presence_in(LOG_GROUPS)
    @group_counts = @group_by ? scope.group(@group_by).count : {}
    order = @group_by ? [@group_by, :id] : [:id]
    @events = scope.order(*order).offset(@event_pages.offset).limit(50).map(&:to_event)
    @object_mappings = mappings_for(@events, key)
    @related_issues, @related_users = related_for(@events, key)
    # A filtered or paged journal opens on its own tab.
    log_params = %i[module_key action_filter source_id flag warning reason group_by page]
    @tab = params[:tab].presence || (log_params.any? { |name| params[name].present? } ? "log" : "summary")
  end

  private

  LOG_GROUPS = %w[module_key action reason].freeze

  def mappings_for(events, connection_key)
    return {} unless connection_key
    missing = events.reject { |event| event.key?("destination_id") }.group_by { |event| event["module"] }
      .transform_values { |rows| rows.map { |event| event["source_id"] }.select { |id| id.is_a?(Integer) }.uniq }
    return {} if missing.empty?
    rows = MirrorMapping.where(connection_key: connection_key, module_key: missing.keys, source_id: missing.values.flatten)
    rows.each_with_object({}) do |row, mappings|
      mappings[[row.module_key, row.source_id]] = row.destination_id if missing.fetch(row.module_key, []).include?(row.source_id)
    end
  end

  # Local issues and users of the related objects shown on this page, in two queries.
  def related_for(events, connection_key)
    related = events.flat_map { |event| view_context.mirror_related_references(event) }
    issue_ids = related.select { |kind, _| kind == "issue_tracking" }.map(&:last).uniq
    user_ids = related.select { |kind, _| kind == "user" }.map(&:last).uniq
    issues = connection_key && issue_ids.any? ? MirrorMapping.where(connection_key: connection_key, module_key: "issue_tracking", source_id: issue_ids).pluck(:source_id, :destination_id).to_h : {}
    rows = user_ids.any? ? @project.mirror_reference_mappings.where(reference_type: "user", source_id: user_ids).to_a : []
    local_users = User.where(id: rows.filter_map(&:destination_id)).index_by(&:id)
    users = rows.to_h { |row| [row.source_id, row.mode == "existing" ? local_users[row.destination_id] : row.mode] }
    [issues, users]
  end

  # Causes that differ only by the source object ID are one cause.
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
