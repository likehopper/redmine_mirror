# frozen_string_literal: true
# File: redmine_mirror/app/controllers/mirror_settings_controller.rb
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
# Authorize project mapping forms and reserve remote connection configuration for administrators.

class MirrorSettingsController < ApplicationController
  helper MirrorHelper
  before_action :find_project_by_project_id
  before_action :authorize
  before_action :require_migrated_schema
  before_action :load_setting
  before_action :require_admin, only: [:update_connection, :refresh]

  def show
    prepare_tabs
  end

  def update_connection
    input = params.require(:connection).permit(:source_url, :source_project_id, :api_key, :source_text_format, modules: [])
    url = input.fetch(:source_url).strip.sub(%r{/+\z}, "")
    # The source project is entered by identifier or numeric ID.
    reference = input.fetch(:source_project_id).to_s.strip
    raise RedmineMirror::Error, l(:text_mirror_invalid_source_project) unless reference.match?(SOURCE_PROJECT)
    if @setting.persisted? && @setting.source_url != url
      # Keep existing correspondence identities stable; rebinding needs an explicit future reset flow.
      raise RedmineMirror::Error, "This project's source cannot be changed after configuration"
    end
    @setting.source_url = url
    @setting.api_key = input[:api_key] if input[:api_key].present?
    unless @setting.persisted? && [@setting.source_project_id.to_s, @setting.source_project_identifier].include?(reference)
      source = resolve_source_project(reference)
      if @setting.persisted? && @setting.source_project_id != source.fetch("id")
        raise RedmineMirror::Error, "This project's source cannot be changed after configuration"
      end
      @setting.source_project_id = source.fetch("id")
      @setting.source_project_identifier = source["identifier"]
    end
    @setting.selected_modules = input[:modules] || []
    @setting.source_text_format = input[:source_text_format] if input[:source_text_format].present?
    if @setting.valid?
      @setting.save!
      # The worker reads the source references; saving stays immediate.
      @setting.request_catalog_refresh!
      flash[:notice] = l(:text_mirror_catalog_requested)
      redirect_to project_mirror_settings_path(@project)
    else
      prepare_tabs
      render :show, status: :unprocessable_entity
    end
  rescue RedmineMirror::Error, ArgumentError, KeyError => error
    @setting.errors.add(:base, error.is_a?(RedmineMirror::Error) ? error.message : l(:text_mirror_invalid_configuration))
    prepare_tabs
    render :show, status: :unprocessable_entity
  end

  def refresh
    return render_404 unless @setting.persisted?
    @setting.request_catalog_refresh!
    flash[:notice] = l(:text_mirror_catalog_requested)
    redirect_to project_mirror_settings_path(@project)
  rescue RedmineMirror::Error => error
    flash[:error] = error.message
    redirect_to project_mirror_settings_path(@project)
  end

  # Resolve the adapter and table from this project’s configuration, then validate
  # every submitted remote ID and local selection before committing the batch.
  def update_mappings
    return render_404 unless @setting.persisted?
    adapter = @setting.adapters.find { |entry| entry.key == params[:module_key] }
    return render_404 unless adapter
    allowed = adapter.mapping_tables.to_h { |table| [table.key, table] }
    input = params.fetch(:mappings, ActionController::Parameters.new).to_unsafe_h
    MirrorReferenceMapping.transaction do
      input.each do |kind, entries|
        table = allowed.fetch(kind) { raise RedmineMirror::Error, "Unknown mapping table" }
        raise RedmineMirror::Error, "Invalid mappings" unless entries.is_a?(Hash)
        entries.each do |source_id, selection|
          unless @setting.source_catalog.fetch(kind, {}).key?(source_id)
            raise RedmineMirror::Error, "Unknown source reference"
          end
          scope = @project.mirror_reference_mappings.where(reference_type: kind, source_id: Integer(source_id))
          if selection.blank?
            scope.destroy_all
          else
            row = scope.first_or_initialize
            row.mode = %w[anonymous ignore].include?(selection) ? selection : "existing"
            row.destination_id = %w[anonymous ignore].include?(selection) ? nil : Integer(selection)
            row.save!
          end
        end
      end
      options = adapter.configuration_options(params.fetch(:module_options, ActionController::Parameters.new).permit(:anonymous_user_id, :missing_target, value_mappings: {}).to_h, @project)
      @setting.update!(module_options: @setting.module_options.merge(adapter.key => options))
    end
    flash[:notice] = l(:notice_successful_update)
    redirect_to project_mirror_settings_path(@project, tab: adapter.key)
  rescue RedmineMirror::Error, ActiveRecord::RecordInvalid, ArgumentError, TypeError
    flash[:error] = l(:text_mirror_invalid_mapping)
    redirect_to project_mirror_settings_path(@project, tab: params[:module_key])
  end

  private

  # After an upgrade without `rake redmine:plugins:migrate`, explain instead of failing.
  def require_migrated_schema
    render_error message: l(:text_mirror_pending_migrations), status: 503 unless MirrorProjectSetting.schema_current?
  end

  SOURCE_PROJECT = /\A(?:[1-9]\d*|[a-z][a-z0-9_-]{0,99})\z/

  # Read the source project once to store its numeric ID and identifier.
  def resolve_source_project(reference)
    project = @setting.source_client.get("projects/#{reference}.json").fetch("project")
    { "id" => Integer(project.fetch("id")), "identifier" => project["identifier"] }
  rescue RedmineMirror::Error, KeyError, TypeError, ArgumentError
    raise RedmineMirror::Error, l(:text_mirror_source_project_not_found)
  end

  def load_setting
    @setting = @project.mirror_project_setting || @project.build_mirror_project_setting
  end

  # Filter and paginate each diagnostic dataset within the authorized project.
  # Date filters use the viewer’s time zone and include the whole final day.
  def prepare_tabs
    @adapters = @setting.persisted? ? @setting.adapters : []
    @tab = (@setting.persisted? && %w[synchronization history objects conflicts].include?(params[:tab])) || @adapters.any? { |entry| entry.key == params[:tab] } ? params[:tab] : "connection"
    if @tab == "conflicts"
      @conflicts = @project.mirror_conflicts.order(updated_at: :desc)
      @conflicts = @conflicts.where(status: params[:conflict_status]) if %w[open ignored resolved].include?(params[:conflict_status])
      @conflict_count = @conflicts.count
      @conflict_pages = Paginator.new(@conflict_count, 25, params[:page])
      @conflicts = @conflicts.limit(25).offset(@conflict_pages.offset)
    end
    if @tab == "history"
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
      if RedmineMirror::REGISTRY.keys.include?(params[:module_key])
        key = MirrorSyncRun.sanitize_sql_like(JSON.generate(params[:module_key]), "!")
        @runs = @runs.where("module_totals LIKE :manifest ESCAPE '!' OR events LIKE :event ESCAPE '!'", manifest: "%#{key}:%", event: "%\"module\":#{key}%")
      end
      @run_count = @runs.count
      @run_pages = Paginator.new(@run_count, 25, params[:page])
      @runs = @runs.limit(25).offset(@run_pages.offset)
    end
    if @tab == "objects"
      destination = ENV["MIRROR_DESTINATION_URL"]
      key = destination.present? ? Digest::SHA256.hexdigest(JSON.generate([@setting.source_url.sub(%r{/+\z}, ""), @setting.source_project_id, destination.sub(%r{/+\z}, ""), @project.id])) : nil
      @objects = MirrorMapping.where(project_id: @project.id)
      @objects = @objects.or(MirrorMapping.where(connection_key: key, project_id: nil)) if key
      @objects = @objects.where(module_key: params[:module_key]) if params[:module_key].present?
      @objects = @objects.where(source_id: params[:source_id]) if params[:source_id].present?
      @objects = @objects.where(destination_id: params[:destination_id]) if params[:destination_id].present?
      @object_count = @objects.count
      @object_pages = Paginator.new(@object_count, 50, params[:page])
      @objects = @objects.order(:module_key, :source_id).limit(50).offset(@object_pages.offset)
    end
    if @tab == "issue_hierarchy"
      @parents = @project.mirror_pending_parents.order(:source_id)
      @parents = @parents.where(status: params[:pending_status]) if %w[pending blocked].include?(params[:pending_status])
      @parent_count = @parents.count
      @parent_pages = Paginator.new(@parent_count, 50, params[:page])
      @parents = @parents.limit(50).offset(@parent_pages.offset)
    end
    @pending_parent_count = @project.mirror_pending_parents.count
    @pending_count = MirrorPendingRelation.where(project_id: @project.id).count
    if @tab == "issue_relations"
      @pending = MirrorPendingRelation.where(project_id: @project.id)
      @pending = @pending.where(status: params[:pending_status]) if %w[pending blocked].include?(params[:pending_status])
      @pending_total = @pending.count
      @pending_pages = Paginator.new(@pending_total, 50, params[:page])
      @pending = @pending.order(:source_id).limit(50).offset(@pending_pages.offset)
    end
    @mapping_values = @project.mirror_reference_mappings.to_h do |row|
      [[row.reference_type, row.source_id.to_s], row.mode == "existing" ? row.destination_id.to_s : row.mode]
    end
  end
end
