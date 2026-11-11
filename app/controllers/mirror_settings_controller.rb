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
  include RedmineMirror::PlainFlash
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
    if MirrorController::TABS.include?(tab) || MirrorController::LEGACY_TABS.key?(tab) || tab == "synchronization"
      operational_tab, anchor = MirrorController::LEGACY_TABS.fetch(tab, [tab])
      redirect_to project_mirror_path(@project, query.merge(tab: (tab == "synchronization" ? nil : operational_tab), anchor: anchor).compact)
    else
      redirect_to settings_project_path(@project, query.merge(tab: "mirror", mirror_tab: tab.presence).compact)
    end
  end

  def update_connection
    input = params.require(:connection).permit(:source_url, :source_project_id, :api_key, :source_text_format, modules: [])
    url = input.fetch(:source_url).strip.sub(%r{/+\z}, "")
    reference = source_project_reference(input)
    check_source_allowed(url) unless @setting.persisted?
    if @setting.persisted? && @setting.source_url != url
      # Keep existing correspondence identities stable; rebinding needs an explicit future reset flow.
      raise RedmineMirror::Error, "This project's source cannot be changed after configuration"
    end
    @setting.source_url = url
    previous_key = @setting[:encrypted_api_key]
    @setting.api_key = input[:api_key] if input[:api_key].present?
    raise RedmineMirror::Error, l(:text_mirror_api_key_missing) if @setting.api_key.blank?
    unless @setting.persisted? && [@setting.source_project_id.to_s, @setting.source_project_identifier].include?(reference)
      source = resolve_source_project(reference)
      if @setting.persisted? && @setting.source_project_id != source.fetch("id")
        raise RedmineMirror::Error, "This project's source cannot be changed after configuration"
      end
      @setting.source_project_id = source.fetch("id")
      @setting.source_project_identifier = source["identifier"]
      @setting.source_catalog = @setting.source_catalog.merge("source_modules" => source["modules"]) if source["modules"]
    end
    @setting.selected_modules = input[:modules] || []
    @setting.source_text_format = input[:source_text_format] if input[:source_text_format].present?
    if @setting.valid?
      @setting.save!
      # Subprojects configured from this project share its key (Subprojects); one given
      # another key in its own settings keeps it.
      if input[:api_key].present? && previous_key
        @setting.child_settings.where(encrypted_api_key: previous_key).update_all(encrypted_api_key: @setting[:encrypted_api_key])
      end
      # The worker reads the source references; saving stays immediate.
      @setting.request_catalog_refresh!
      flash[:notice] = l(:text_mirror_catalog_requested)
    else
      flash[:error] = @setting.errors.full_messages.to_sentence
      keep_typed_connection
    end
    redirect_to configuration_path
  rescue RedmineMirror::Error, ArgumentError, KeyError => error
    flash[:error] = error.is_a?(RedmineMirror::Error) ? error.message : l(:text_mirror_invalid_configuration)
    keep_typed_connection
    redirect_to configuration_path
  end

  # Read the connection typed in the form without saving anything: mirror.js shows the
  # result in the form. A saved connection keeps its source and, left blank, its key.
  def check_connection
    input = params.require(:connection).permit(:source_url, :source_project_id, :api_key)
    reference = source_project_reference(input)
    unless @setting.persisted?
      @setting.source_url = input.fetch(:source_url).strip.sub(%r{/+\z}, "")
      check_source_allowed(@setting.source_url)
    end
    # The stored key reads only the configured source project: managers never see it.
    if @setting.persisted? && input[:api_key].blank? && ![@setting.source_project_id.to_s, @setting.source_project_identifier].include?(reference)
      raise RedmineMirror::Error, l(:text_mirror_check_other_project_needs_key)
    end
    @setting.api_key = input[:api_key] if input[:api_key].present?
    raise RedmineMirror::Error, l(:text_mirror_api_key_missing) if @setting.api_key.blank?
    check = RedmineMirror::ConnectionCheck.new(client: @setting.source_client, project_reference: reference).run
    render partial: "mirror_settings/connection_check", locals: { check: check }
  rescue RedmineMirror::Error, ActionController::ParameterMissing, KeyError => error
    render partial: "mirror_settings/connection_check", locals: { check: { "error" => "input", "detail" => error.is_a?(RedmineMirror::Error) ? error.message : l(:text_mirror_invalid_configuration) } }
  end

  # Link the chosen source subprojects to local subprojects, created or existing, each with
  # its own Mirror configuration taken from this one (RedmineMirror::Subprojects).
  def update_subprojects
    return render_404 unless @setting.persisted? && @setting.parent_setting_id.nil?
    input = params[:subprojects].respond_to?(:to_unsafe_h) ? params[:subprojects].to_unsafe_h : {}
    result = RedmineMirror::Subprojects.new(@setting).apply(input, User.current)
    flash[:notice] = l(:text_mirror_subprojects_linked, count: result.linked.size, names: result.linked.map(&:name).join(", ")) if result.linked.any?
    flash[:error] = result.errors.map { |name, message| l(:text_mirror_catalog_module_error, module: name, error: message) }.join(" ; ") if result.errors.any?
    redirect_to configuration_path(nil, anchor: "mirror-subprojects")
  end

  # Read the source subprojects again (one request), without the whole references.
  def refresh_subprojects
    return render_404 unless @setting.persisted? && @setting.parent_setting_id.nil?
    subprojects, refusal = RedmineMirror::ConnectionCheck.new(client: @setting.source_client, project_reference: @setting.source_project_id)
      .subprojects(@setting.source_project_id)
    # lock! reloads the row: a catalog the worker saved meanwhile is kept.
    @setting.with_lock do
      @setting.update_columns(source_catalog: JSON.generate(@setting.source_catalog.merge("subprojects" => subprojects, "subprojects_refusal" => refusal)))
    end
    redirect_to configuration_path(nil, anchor: "mirror-subprojects")
  rescue RedmineMirror::Error => error
    flash[:error] = error.message
    redirect_to configuration_path(nil, anchor: "mirror-subprojects")
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

  # Whether the administrator's defaults fill this project by themselves.
  def update_defaults
    return render_404 unless @setting.persisted?
    @setting.update_columns(use_default_mappings: params[:use_default_mappings] == "1", updated_at: Time.current)
    flash[:notice] = l(:notice_successful_update)
    redirect_to configuration_path
  end

  # Apply the defaults now: fill the references without correspondence, or with `reset`
  # also replace those whose name has a default. The source is not read again.
  def apply_defaults
    return render_404 unless @setting.persisted? && [nil, "ready"].include?(@setting.catalog_status)
    count = RedmineMirror::DefaultMappings.apply(@setting, reset: params[:reset] == "1")
    flash[:notice] = l(:text_mirror_project_defaults_applied, count: count)
    redirect_to configuration_path
  end

  # One-click fixes of the checklist, each under the permission Redmine itself asks for:
  # enable a project module, or unselect the Mirror modules that need it; enable the
  # mapped trackers or a mapped field in this project; select a module the source has
  # data for. Back to where the person came from.
  def fix_setup
    return render_404 unless @setting.persisted?
    case params[:fix]
    when "enable_module"
      name = params[:target].to_s
      return deny_access unless User.current.allowed_to?(:select_project_modules, @project)
      raise RedmineMirror::Error, "Unknown project module" unless @setting.adapters.any? { |adapter| adapter.project_module.to_s == name }
      @project.enable_module!(name)
    when "unselect_module"
      name = params[:target].to_s
      kept = @setting.selected_modules.select do |key|
        RedmineMirror::REGISTRY[key] && RedmineMirror::REGISTRY.resolve([key]).none? { |adapter| adapter.project_module.to_s == name }
      end
      raise RedmineMirror::Error, l(:text_mirror_nothing_left_to_import) if kept.empty?
      @setting.selected_modules = kept
      @setting.save!
    when "enable_trackers"
      return deny_access unless User.current.allowed_to?(:edit_project, @project)
      used = @setting.source_catalog["tracker_used"]
      ids = @project.mirror_reference_mappings.where(reference_type: "tracker", mode: "existing").select { |row| used.nil? || used.include?(row.source_id.to_s) }.map(&:destination_id)
      @project.trackers << (Tracker.where(id: ids).to_a - @project.trackers.to_a)
    when "enable_tracker"
      return deny_access unless User.current.allowed_to?(:edit_project, @project)
      tracker = Tracker.find_by(id: params[:target])
      raise RedmineMirror::Error, "Unknown tracker" unless tracker && source_namesake?("tracker", tracker.name)
      @project.trackers << tracker unless @project.trackers.include?(tracker)
    when "enable_custom_field"
      return deny_access unless User.current.allowed_to?(:edit_project, @project)
      field = IssueCustomField.find_by(id: params[:target])
      mapped = field && @project.mirror_reference_mappings.where(reference_type: "custom_field", destination_id: field.id).exists?
      raise RedmineMirror::Error, "Unknown custom field" unless mapped || (field && source_namesake?("custom_field", field.name))
      @project.issue_custom_fields << field unless field.is_for_all? || @project.issue_custom_fields.include?(field)
    when "select_module"
      key = params[:target].to_s
      raise RedmineMirror::Error, "Unknown module" unless RedmineMirror::REGISTRY[key]&.available? && RedmineMirror::REGISTRY[key].selectable?
      @setting.selected_modules = @setting.selected_modules + [key]
      @setting.save!
      @setting.request_catalog_refresh!
    else
      return render_404
    end
    flash[:notice] = l(:notice_successful_update)
    redirect_back_or_default configuration_path
  rescue RedmineMirror::Error, ActiveRecord::RecordInvalid => error
    flash[:error] = error.message
    redirect_back_or_default configuration_path
  end

  # Resolve the adapter and table from this project’s configuration, then validate
  # every submitted remote ID and local selection before committing the batch.
  def update_mappings
    return render_404 unless @setting.persisted?
    adapter = @setting.adapters.find { |entry| entry.key == params[:module_key] }
    return render_404 unless adapter
    allowed = adapter.mapping_tables.to_h { |table| [table.key, table] }
    input = params.fetch(:mappings, ActionController::Parameters.new).to_unsafe_h
    # A checked special choice (anonymize, ignore) wins over the row's field.
    special = params.fetch(:special_mappings, ActionController::Parameters.new).to_unsafe_h
    MirrorReferenceMapping.transaction do
      input.each do |kind, entries|
        table = allowed.fetch(kind) { raise RedmineMirror::Error, "Unknown mapping table" }
        raise RedmineMirror::Error, "Invalid mappings" unless entries.is_a?(Hash)
        entries.each do |source_id, selection|
          if (choice = special.dig(kind, source_id).presence)
            unless (choice == "anonymous" && table.anonymous_allowed?) || (choice == "ignore" && table.ignore_allowed?)
              raise RedmineMirror::Error, "Invalid special choice"
            end
            selection = choice
          end
          unless @setting.source_catalog.fetch(kind, {}).key?(source_id)
            raise RedmineMirror::Error, "Unknown source reference"
          end
          scope = @project.mirror_reference_mappings.where(reference_type: kind, source_id: Integer(source_id))
          if selection.blank?
            scope.destroy_all
          else
            row = scope.first_or_initialize
            # Its validation then reads this setting's catalog, parsed once, not once per row.
            row.project = @project
            literal = %w[anonymous ignore].include?(selection) || table.extra_choices.include?(selection)
            row.mode = literal ? selection : "existing"
            row.destination_id = literal ? nil : Integer(selection)
            # A correspondence changed by hand no longer comes from an administrator's default.
            row.from_default = false if row.changed?
            row.save!
          end
        end
      end
      options = adapter.configuration_options(params.fetch(:module_options, ActionController::Parameters.new).permit(:anonymous_user_id, :missing_target, :unmapped, :priority_fallback, :priority_field, :tracker_field, :path_rewrites, :credentials, :fetch_changesets, value_mappings: {}, priority_values: {}, tracker_values: {}).to_h, @project)
      @setting.update!(module_options: @setting.module_options.merge(adapter.key => options))
    end
    flash[:notice] = l(:notice_successful_update)
    redirect_to configuration_path(adapter.key, mirror_filter: params[:mirror_filter].presence_in(%w[unmapped mapped all]))
  rescue RedmineMirror::Error, ActiveRecord::RecordInvalid, ArgumentError, TypeError => error
    # The cause follows, so that the page says what to fix ("Unavailable modules: news").
    cause = case error
            when ActiveRecord::RecordInvalid then error.record.errors.full_messages.join(", ")
            when RedmineMirror::Error then error.message
            end
    flash[:error] = [l(:text_mirror_invalid_mapping), cause.presence].compact.join(" ")
    redirect_to configuration_path(params[:module_key])
  end

  # Queue AI proposals for one mapping table (doc/AI.md). The worker asks the API as the
  # current user, within the administrator's daily limit; nothing is saved.
  def request_ai
    return render_404 unless @setting.persisted?
    adapter = @setting.adapters.find { |entry| entry.key == params[:module_key] }
    table = adapter&.mapping_tables&.find { |entry| entry.key == params[:table] }
    return render_404 unless table
    config = MirrorAiConfig.current
    raise RedmineMirror::Error, l(:text_mirror_ai_unavailable) unless config.usable? && RedmineMirror::Ai.tables(config).include?(table.key)
    raise RedmineMirror::Error, l(:text_mirror_ai_budget_exhausted) if config.budget_left.zero?
    if RedmineMirror::Ai.pending_sources(@setting, table).size < config.min_references
      raise RedmineMirror::Error, l(:text_mirror_ai_below_threshold, count: config.min_references)
    end
    @setting.with_lock do
      raise RedmineMirror::Error, l(:text_mirror_ai_already_requested) if %w[pending running].include?(@setting.ai_status)
      @setting.update_columns(ai_status: "pending", ai_tables: JSON.generate([table.key]), ai_requested_by_id: User.current.id,
        ai_requested_at: Time.current, ai_error: nil)
    end
    flash[:notice] = l(:text_mirror_ai_queued)
    redirect_to configuration_path(adapter.key)
  rescue RedmineMirror::Error => error
    flash[:error] = error.message
    redirect_to configuration_path(params[:module_key])
  end

  # Create registered accounts (awaiting activation, as a self-registration) for source
  # users whose email the source shares, map them, and add them as members with the roles
  # the current user may give. Administrators receive Redmine's activation request.
  def create_users
    return render_404 unless @setting.persisted?
    raise RedmineMirror::Error, l(:text_mirror_user_creation_denied) unless RedmineMirror.user_creation?(@project)
    role_ids = Array(params[:role_ids]).reject(&:blank?).map { |id| Integer(id) }.uniq
    roles = User.current.managed_roles(@project).select { |role| role_ids.include?(role.id) }
    raise RedmineMirror::Error, l(:text_mirror_invalid_mapping) unless roles.size == role_ids.size
    details = @setting.source_catalog.fetch("user_details", {})
    created = []
    errors = []
    Array(params[:source_user_ids]).map(&:to_s).uniq.each do |source_id|
      info = details[source_id]
      next errors << source_id unless info && info["mail"].present?
      user = create_registered_user(Integer(source_id), info, roles)
      user.persisted? ? created << user : errors << "#{info['firstname']} #{info['lastname']}: #{user.errors.full_messages.to_sentence}"
    end
    flash[:notice] = l(:text_mirror_users_created, count: created.size, names: created.map(&:name).join(", ")) if created.any?
    flash[:error] = l(:text_mirror_users_not_created, errors: errors.join(" ; ")) if errors.any?
    redirect_to configuration_path("users", anchor: "mirror-user-creation")
  rescue RedmineMirror::Error, ArgumentError, TypeError => error
    flash[:error] = error.is_a?(RedmineMirror::Error) ? error.message : l(:text_mirror_invalid_mapping)
    redirect_to configuration_path("users")
  end

  private

  # Unsaved, with its errors, when the email already has an account, the source user is
  # already mapped, or Redmine refuses the account (login taken, required user field...).
  def create_registered_user(source_id, info, roles)
    user = User.new(firstname: info["firstname"], lastname: info["lastname"], mail: info["mail"], language: Setting.default_language)
    user.login = info["login"]
    user.status = User::STATUS_REGISTERED
    company = RedmineMirror.user_company_field
    user.custom_field_values = { company.id.to_s => info["company"] } if company && info["company"].present?
    mapping = @project.mirror_reference_mappings.where(reference_type: "user", source_id: source_id)
    user.errors.add(:base, l(:text_mirror_user_already_mapped)) if mapping.exists?
    user.errors.add(:mail, :taken) if EmailAddress.where("LOWER(address) = ?", info["mail"].to_s.downcase).exists?
    return user if user.errors.any?
    User.transaction do
      user.save!
      mapping.create!(mode: "existing", destination_id: user.id)
      Member.create!(project: @project, principal: user, roles: roles) if roles.any?
    end
    Mailer.deliver_account_activation_request(user)
    user
  rescue ActiveRecord::RecordInvalid => error
    # The transaction rolled back: the account is unsaved again.
    user.errors.add(:base, error.record.errors.full_messages.to_sentence) unless error.record.equal?(user)
    user
  end

  # After an upgrade without `rake redmine:plugins:migrate`, explain instead of failing.
  def require_migrated_schema
    render_error message: l(:text_mirror_pending_migrations), status: 503 unless MirrorProjectSetting.schema_current?
  end

  SOURCE_PROJECT = /\A(?:[1-9]\d*|[a-z][a-z0-9_-]{0,99})\z/

  # A local tracker or field named like a source reference (the checklist's near misses).
  def source_namesake?(kind, name)
    key = RedmineMirror::NameMatch.key(name)
    @setting.source_catalog.fetch(kind, {}).values.any? { |source| RedmineMirror::NameMatch.key(source) == key }
  end

  # The source project is entered by identifier or numeric ID.
  def source_project_reference(input)
    reference = input.fetch(:source_project_id).to_s.strip
    raise RedmineMirror::Error, l(:text_mirror_invalid_source_project) unless reference.match?(SOURCE_PROJECT)
    reference
  end

  # The form of a refused first connection is shown again with what was typed
  # (prepare_mirror_configuration reads it once). Never the API key: the session may be a
  # cookie, whose size also bounds the kept values. Not the flash: some Redmine versions
  # display every flash entry.
  def keep_typed_connection
    connection = params[:connection]
    return if @setting.persisted? || !connection.is_a?(ActionController::Parameters)
    session[:mirror_typed_connection] = { "source_url" => connection[:source_url].to_s[0, 200],
      "source_project_id" => connection[:source_project_id].to_s[0, 100],
      "source_text_format" => connection[:source_text_format].to_s[0, 20] }
  end

  # A source must be allowed in the plugin settings; while none is, administrators
  # may still connect to any source.
  def check_source_allowed(url)
    return if User.current.admin? && RedmineMirror.allowed_source_urls.empty?
    raise RedmineMirror::Error, l(:text_mirror_source_not_allowed) unless RedmineMirror.allowed_source_url?(url)
  end

  # Read the source project once to store its numeric ID and identifier, and its modules
  # so that the module list greys the missing ones before the references are read.
  def resolve_source_project(reference)
    project = @setting.source_client.get("projects/#{reference}.json", "include" => "enabled_modules").fetch("project")
    modules = project["enabled_modules"].map { |entry| entry["name"].to_s } if project["enabled_modules"].is_a?(Array)
    { "id" => Integer(project.fetch("id")), "identifier" => project["identifier"], "modules" => modules }
  rescue RedmineMirror::Error, KeyError, TypeError, ArgumentError
    raise RedmineMirror::Error, l(:text_mirror_source_project_not_found)
  end

  def load_setting
    @setting = @project.mirror_project_setting || @project.build_mirror_project_setting
  end

  def configuration_path(mirror_tab = nil, **options)
    settings_project_path(@project, { tab: "mirror", mirror_tab: mirror_tab }.merge(options).compact)
  end
end
