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
  before_action :require_destination, except: :source
  before_action :require_migrated_schema, only: :index
  before_action :require_source_schema, only: :source
  before_action :require_ai_schema, only: [:ai, :update_ai, :test_ai]
  before_action :require_defaults_schema, only: [:defaults, :create_default, :destroy_default, :import_defaults, :apply_defaults]

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

  # Administration > Mirror > Default correspondences (doc/DEFAULT_MAPPINGS.md), or their CSV.
  def defaults
    @rules = MirrorDefaultMapping.sorted.preload(:custom_field).to_a
    respond_to do |format|
      format.html do
        @list_fields = MirrorDefaultMapping.list_fields
        @field = @list_fields.find { |field| field.id.to_s == params[:custom_field_id].to_s } || @list_fields.first
      end
      format.csv do
        send_data(RedmineMirror::DefaultMappings.to_csv(@rules), type: "text/csv; header=present", filename: "mirror-default-mappings.csv")
      end
    end
  end

  # One default per source name, all with the same destination; no name gives the fallback.
  def create_default
    input = params.require(:default_mapping).permit(:reference_type, :source_names, :source_url, :destination, :custom_field_id)
    names = input[:source_names].to_s.split(/\r?\n/).map(&:strip).reject(&:empty?).uniq { |name| RedmineMirror::NameMatch.key(name) }
    destination = input[:destination].to_s
    rules = (names.presence || [nil]).map do |name|
      rule = MirrorDefaultMapping.new(reference_type: input[:reference_type], source_name: name, source_url: input[:source_url],
        custom_field_id: input[:custom_field_id].presence)
      if rule.reference_type == "custom_field_value"
        rule.destination_value = destination
      elsif %w[ignore anonymous].include?(destination)
        rule.mode = destination
      else
        rule.destination_id = destination.match?(/\A\d+\z/) ? destination.to_i : nil
      end
      rule
    end
    invalid = rules.reject(&:valid?)
    if invalid.empty?
      MirrorDefaultMapping.transaction { rules.each(&:save!) }
      flash[:notice] = l(:notice_successful_create)
    else
      flash[:error] = invalid.map { |rule| "#{rule.source_name || l(:label_mirror_default_fallback)}: #{rule.errors.full_messages.to_sentence}" }.join("; ")
    end
    redirect_to defaults_path(input[:reference_type], input[:custom_field_id])
  end

  def destroy_default
    rule = MirrorDefaultMapping.find(params[:id])
    rule.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to defaults_path(rule.reference_type, rule.custom_field_id)
  end

  def import_defaults
    file = params[:file]
    if file.respond_to?(:read)
      count, errors = RedmineMirror::DefaultMappings.import(file.read)
      if errors.empty?
        flash[:notice] = l(:text_mirror_defaults_imported, count: count)
      else
        flash[:error] = l(:text_mirror_defaults_import_failed, errors: errors.first(20).join("; "))
      end
    else
      flash[:error] = l(:text_mirror_defaults_import_failed, errors: l(:label_no_data))
    end
    redirect_to mirror_admin_defaults_path
  rescue RedmineMirror::Error => error
    flash[:error] = l(:text_mirror_defaults_import_failed, errors: error.message)
    redirect_to mirror_admin_defaults_path
  end

  # Fills the projects from the source references they already read; no source is read.
  def apply_defaults
    flash[:notice] = l(:text_mirror_defaults_applied, count: RedmineMirror::DefaultMappings.apply_all)
    redirect_to mirror_admin_defaults_path
  end

  private

  def defaults_path(type, custom_field_id)
    mirror_admin_defaults_path(custom_field_id: (custom_field_id.presence if type == "custom_field_value"), anchor: "mirror-defaults-#{type}")
  end

  def require_defaults_schema
    render_error message: l(:text_mirror_pending_migrations), status: 503 unless MirrorDefaultMapping.schema_current?
  end

  # A source-only Redmine (below Redmine 5) has no destination or AI pages.
  def require_destination
    return unless RedmineMirror.source_only?
    action_name == "index" ? redirect_to(mirror_admin_source_path) : render_404
  end

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
