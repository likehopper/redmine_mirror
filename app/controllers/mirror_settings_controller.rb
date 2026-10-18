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
# Save the configuration shown in the Mirror tab of the project settings. Non-administrators
# connect only to source URLs an administrator allowed in the plugin settings.

class MirrorSettingsController < ApplicationController
  include RedmineMirror::Authorization
  helper MirrorHelper
  before_action :find_project_by_project_id
  before_action -> { authorize_mirror(:manage) }
  before_action :require_migrated_schema
  before_action :load_setting

  # The configuration is the Mirror tab of the project settings and the operations are
  # the Mirror page: former links (?tab=...) lead to their new place.
  def show
    tab = params[:tab].to_s
    query = request.query_parameters.except("tab").symbolize_keys
    if MirrorController::TABS.include?(tab) || tab == "synchronization"
      redirect_to project_mirror_path(@project, query.merge(tab: (tab == "synchronization" ? nil : tab)).compact)
    else
      redirect_to settings_project_path(@project, query.merge(tab: "mirror", mirror_tab: tab.presence).compact)
    end
  end

  def update_connection
    input = params.require(:connection).permit(:source_url, :source_project_id, :api_key, :source_text_format, modules: [])
    url = input.fetch(:source_url).strip.sub(%r{/+\z}, "")
    # The source project is entered by identifier or numeric ID.
    reference = input.fetch(:source_project_id).to_s.strip
    raise RedmineMirror::Error, l(:text_mirror_invalid_source_project) unless reference.match?(SOURCE_PROJECT)
    # Other members connect only to a source an administrator allowed (plugin settings).
    if !User.current.admin? && !@setting.persisted? && !RedmineMirror.allowed_source_url?(url)
      raise RedmineMirror::Error, l(:text_mirror_source_not_allowed)
    end
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
    else
      flash[:error] = @setting.errors.full_messages.to_sentence
    end
    redirect_to configuration_path
  rescue RedmineMirror::Error, ArgumentError, KeyError => error
    flash[:error] = error.is_a?(RedmineMirror::Error) ? error.message : l(:text_mirror_invalid_configuration)
    redirect_to configuration_path
  end

  def refresh
    return render_404 unless @setting.persisted?
    @setting.request_catalog_refresh!
    flash[:notice] = l(:text_mirror_catalog_requested)
    redirect_to configuration_path
  rescue RedmineMirror::Error => error
    flash[:error] = error.message
    redirect_to configuration_path
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
    redirect_to configuration_path(adapter.key)
  rescue RedmineMirror::Error, ActiveRecord::RecordInvalid, ArgumentError, TypeError
    flash[:error] = l(:text_mirror_invalid_mapping)
    redirect_to configuration_path(params[:module_key])
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

  def configuration_path(mirror_tab = nil)
    settings_project_path(@project, { tab: "mirror", mirror_tab: mirror_tab }.compact)
  end
end
