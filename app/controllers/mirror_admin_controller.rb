# frozen_string_literal: true
# File: redmine_mirror/app/controllers/mirror_admin_controller.rb
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
# Administration > Mirror: as a destination, the projects Mirror is configured in, their
# activity and load; as a source, the projects sharing data and every access to it.

class MirrorAdminController < ApplicationController
  layout "admin"
  self.main_menu = false
  menu_item :mirror_admin
  before_action :require_admin
  before_action :require_migrated_schema, only: :index
  before_action :require_source_schema, only: :source
  before_action :require_ai_schema, only: [:ai, :update_ai, :test_ai]

  helper :queries
  include QueriesHelper
  helper MirrorHelper

  def index
    retrieve_query(MirrorProjectQuery, false)
    return unless @query.valid?
    respond_to do |format|
      format.html do
        @setting_count = @query.base_scope.count
        @setting_pages = Paginator.new(@setting_count, per_page_option, params["page"])
        @settings = @query.results(offset: @setting_pages.offset, limit: @setting_pages.per_page)
      end
      format.csv do
        send_data(query_to_csv(@query.results, @query, params), type: "text/csv; header=present", filename: "mirror-projects.csv")
      end
    end
  rescue Query::StatementInvalid
    render_error status: 500
  end

  SESSIONS_PER_PAGE = 50

  # Mirror source: the switch, the projects that enabled the module and what they share,
  # then the sessions of every project (filtered by project or refusals), or one session.
  def source
    @sharing = MirrorSourceSetting.preload(:project).where(project_id: EnabledModule.where(name: "mirror_source").select(:project_id)).to_a
    @module_projects = Project.where(id: EnabledModule.where(name: "mirror_source").select(:project_id)).sorted.to_a
    @last_access = MirrorSourceAccess.group(:project_id).maximum(:created_at)
    @session_counts = MirrorSourceAccess.from(MirrorSourceAccess.select(:project_id, :session_key).distinct, :mirror_source_accesses).group(:project_id).count
    @session_key = params[:session].to_s
    if @session_key.match?(RedmineMirror::Source::SESSION) && (@session_project = Project.find_by(id: params[:project_id]))
      @accesses = MirrorSourceAccess.where(project: @session_project, session_key: @session_key).order(:created_at, :id).preload(:user).to_a
      return
    end
    scope = MirrorSourceAccess.all
    @filter_project = Project.find_by(id: params[:project_id]) if params[:project_id].present?
    scope = scope.where(project: @filter_project) if @filter_project
    @refused_only = params[:refused] == "1"
    sessions = scope.sessions
    sessions = sessions.having("SUM(CASE WHEN action = 'refused' THEN 1 ELSE 0 END) > 0") if @refused_only
    @session_count = MirrorSourceAccess.from(sessions.except(:order, :select).select(:project_id, :session_key), :mirror_source_accesses).count
    @session_pages = Paginator.new(@session_count, SESSIONS_PER_PAGE, params["page"])
    @sessions = sessions.offset(@session_pages.offset).limit(@session_pages.per_page).to_a
  end

  # Administration > Mirror > AI (doc/AI.md): provider, key, model, limits and usage.
  def ai
    @config = MirrorAiConfig.current
    @usages = MirrorAiUsage.where("day >= ?", Date.current - 29).order(day: :desc).to_a
  end

  # The key is write-only: an empty field keeps it, the delete box removes it.
  def update_ai
    @config = MirrorAiConfig.current
    input = params.require(:ai).permit(:enabled, :provider, :url, :model, :send_user_names, :min_references, :daily_request_limit)
    @config.assign_attributes(input)
    @config.api_key = params[:ai][:api_key] if params[:ai][:api_key].present?
    @config.api_key = nil if params[:ai][:clear_api_key] == "1"
    if @config.save
      flash[:notice] = l(:notice_successful_update)
    else
      flash[:error] = @config.errors.full_messages.to_sentence
    end
    redirect_to mirror_admin_ai_path
  rescue RedmineMirror::Error => error
    flash[:error] = error.message
    redirect_to mirror_admin_ai_path
  end

  # Lists the models: checks the key without spending credit, and lifts a block.
  def test_ai
    config = MirrorAiConfig.current
    return redirect_to(mirror_admin_ai_path) unless config.persisted?
    ids = config.test_connection!
    flash[:notice] = l(:text_mirror_ai_test_succeeded, count: ids.size)
    redirect_to mirror_admin_ai_path
  rescue RedmineMirror::Error, ActiveRecord::RecordInvalid => error
    flash[:error] = l(:text_mirror_ai_test_failed, message: error.message)
    redirect_to mirror_admin_ai_path
  end

  private

  def require_ai_schema
    return if MirrorAiConfig.table_exists? && MirrorProjectSetting.schema_current?
    render_error message: l(:text_mirror_pending_migrations), status: 503
  end

  def require_source_schema
    return if MirrorSourceAccess.table_exists? && MirrorSourceSetting.table_exists?
    render_error message: l(:text_mirror_pending_migrations), status: 503
  end

  def require_migrated_schema
    return if MirrorProjectSetting.schema_current? && MirrorSyncRun.column_names.include?("duration_seconds")
    render_error message: l(:text_mirror_pending_migrations), status: 503
  end
end
