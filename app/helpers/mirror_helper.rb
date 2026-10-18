# frozen_string_literal: true
# File: redmine_mirror/app/helpers/mirror_helper.rb
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
# Build native and remote object links without exposing configured API credentials.

module MirrorHelper
  # The Mirror page of the project menu: overview, history, conflicts, pending links, objects.
  def mirror_page_path(project, tab = nil, **options)
    project_mirror_path(project, { tab: tab }.compact.merge(options))
  end

  # The Mirror tab of the project settings: connection, schedule and module mappings.
  def mirror_configuration_path(project, mirror_tab = nil, **options)
    settings_project_path(project, { tab: "mirror", mirror_tab: mirror_tab }.compact.merge(options))
  end

  def mirror_can_run?(project)
    RedmineMirror.runner?(project)
  end

  def mirror_manager?(project)
    RedmineMirror.manager?(project)
  end

  # Data of the Mirror tab, rendered inside Redmine's project settings page.
  def prepare_mirror_configuration(project)
    @setting = project.mirror_project_setting || project.build_mirror_project_setting
    @adapters = @setting.persisted? ? @setting.adapters : []
    tabs = ["connection"] + (@setting.persisted? ? ["schedule"] + @adapters.map(&:key) : [])
    @mirror_tab = tabs.include?(params[:mirror_tab]) ? params[:mirror_tab] : "connection"
    @mapping_values = project.mirror_reference_mappings.to_h do |row|
      [[row.reference_type, row.source_id.to_s], row.mode == "existing" ? row.destination_id.to_s : row.mode]
    end
  end

  # Source references used by the project that have no correspondence yet, per module.
  def mirror_unmapped_counts(project, setting)
    return {} unless setting&.persisted?
    @mirror_unmapped_counts ||= begin
      catalog = setting.source_catalog
      mapped = project.mirror_reference_mappings.pluck(:reference_type, :source_id).map { |kind, id| [kind, id.to_s] }.to_set
      setting.adapters.each_with_object({}) do |adapter, counts|
        count = adapter.mapping_tables.sum do |table|
          ids = catalog.fetch(table.key, {}).keys
          used = catalog["#{table.key}_used"]
          ids &= used if used
          ids.count { |id| !mapped.include?([table.key, id]) }
        end
        counts[adapter.key] = count if count.positive?
      end
    end
  end

  # Getting started: each step with its state (:done, :waiting, :failed or :todo), a
  # detail and the page where it is done. Scheduling is optional.
  def mirror_setup_steps(project, setting)
    connected = setting&.persisted?
    runs = connected ? project.mirror_sync_runs.where(status: %w[succeeded partial]) : nil
    catalog = if !connected then :todo
              elsif setting.catalog_refreshing? then :waiting
              elsif setting.catalog_status == "failed" then :failed
              else :done
              end
    unmapped = mirror_unmapped_counts(project, setting)
    mappings = catalog != :done ? :todo : (unmapped.empty? ? :done : :todo)
    synchronized = connected && runs.where(apply: true).exists?
    previewed = synchronized || (connected && runs.where(apply: false).exists?)
    [
      [:connection, connected ? :done : :todo, nil, mirror_configuration_path(project)],
      [:references, catalog, (setting.catalog_error if catalog == :failed), mirror_configuration_path(project)],
      [:mappings, mappings, unmapped.map { |key, count| "#{mirror_module_label(key)} #{count}" }.join(", ").presence,
        mirror_configuration_path(project, unmapped.keys.first)],
      [:preview, previewed ? :done : :todo, nil, mirror_page_path(project)],
      [:sync, synchronized ? :done : :todo, nil, mirror_page_path(project)],
      [:schedule, connected && setting.auto_sync_enabled? ? :done : :todo, nil, mirror_configuration_path(project, "schedule")]
    ]
  end

  # Getting started is shown until a first synchronization succeeded.
  def mirror_setup_complete?(steps)
    steps.first(5).all? { |step| step[1] == :done }
  end

  # Local record with the same name as an unmapped source reference, preselected in the
  # mapping form for the user to check and save.
  def mirror_name_suggestion(choices, name)
    return nil if name.blank?
    matches = choices.select { |label, value| value.match?(/\A\d+\z/) && label.sub(/ \(#\d+\)( - .*)?\z/, "").casecmp?(name.to_s.strip) }
    matches.one? ? matches.first.last : nil
  end
  # Name of a Redmine text formatting, as in the administration settings.
  def mirror_text_format_name(format)
    return "—" if format.blank?
    Redmine::WikiFormatting.formats_for_select.find { |_, name| name.to_s == format.to_s }&.first || format
  end

  def mirror_module_label(key)
    # Wiki attachments have their own correspondences, inside the Wiki module.
    RedmineMirror::REGISTRY.keys.include?(key) || key == "wiki_attachments" ? l("label_mirror_module_#{key}".to_sym) : key
  end

  MAPPING_TABS = { "status" => "issue_tracking", "tracker" => "issue_tracking", "priority" => "issue_tracking",
    "user" => "users", "activity" => "time_tracking", "custom_field" => "issue_custom_fields" }.freeze

  # An error or warning with, when known, the source reference name and a link to the
  # page that fixes it.
  def mirror_reason(reason)
    text = reason.to_s
    name, label, path = mirror_fix(text)
    parts = [text]
    parts << " (#{name})" if name
    parts << " — " << link_to(l(label), path, class: "mirror-fix") if path
    safe_join(parts)
  end

  # [source reference name, link label, path] for the causes Mirror knows how to fix.
  def mirror_fix(text)
    return [] unless @setting
    if (match = text.match(/\AMissing (\w+) mapping for source ID (\d+)/))
      kind, id = match.captures
      tab = MAPPING_TABS[kind]
      [@setting.source_catalog.dig(kind, id), :label_mirror_fix_mapping, tab && mirror_manager?(@project) && mirror_configuration_path(@project, tab)]
    elsif (match = text.match(/\ACustom field "(.+?)" is not enabled for destination tracker/))
      field = IssueCustomField.find_by(name: match[1])
      if User.current.admin? && field
        [nil, :label_mirror_fix_field_trackers, edit_custom_field_path(field)]
      else
        [nil, :label_mirror_fix_ignore_field, mirror_manager?(@project) && mirror_configuration_path(@project, "issue_custom_fields")]
      end
    elsif text.include?("is not enabled in this project")
      [nil, :label_mirror_fix_project_fields, User.current.allowed_to?(:edit_project, @project) && settings_project_path(@project, tab: "issues")]
    elsif text.match?(/value mapping for custom field|incompatible formats|Invalid value for custom field|custom_field mapping/)
      [nil, :label_mirror_fix_mapping, mirror_manager?(@project) && mirror_configuration_path(@project, "issue_custom_fields")]
    elsif text.start_with?("Local modification detected")
      [nil, :label_mirror_fix_conflict, mirror_page_path(@project, "conflicts")]
    elsif text.include?("maximum attachment size") && User.current.admin?
      [nil, :label_mirror_fix_attachment_size, settings_path(tab: "attachments")]
    else
      []
    end
  end

  # "converted:textile>html" reads "Converted: Textile → HTML (CKEditor)".
  def mirror_flag_label(flag)
    name, detail = flag.to_s.split(":", 2)
    return l("label_mirror_flag_#{name}", default: name) unless detail
    from, to = detail.split(">", 2)
    l("label_mirror_flag_#{name}", detail: [from, to].map { |format| l("label_mirror_text_format_#{format}", default: format.to_s) }.join(" → "), default: flag)
  end

  def mirror_extension(key)
    RedmineMirror::REGISTRY[key] || RedmineMirror::REGISTRY.mapping_table(key)
  end

  def mirror_object_link(module_key, id, source_url: nil, local_issue_id: nil)
    return "—" if id.blank?
    id = Integer(id)
    local_id = source_url && @project ? MirrorMapping.find_by(project_id: @project.id, module_key: module_key, source_id: id)&.destination_id : id
    if %w[issue_journals issue_relation_notes].include?(module_key)
      local_issue_id ||= Journal.find_by(id: local_id)&.journalized_id if local_id
    elsif module_key == "issue_relations"
      local_issue_id ||= IssueRelation.find_by(id: local_id)&.issue_from_id if local_id
    end
    remote_issue_id = source_url && local_issue_id && @project ? MirrorMapping.find_by(project_id: @project.id, module_key: "issue_tracking", destination_id: local_issue_id)&.source_id : nil
    path = case module_key
           when "user", "users" then user_path(id)
           when "custom_field" then "/custom_fields/#{id}/edit"
           when "tracker" then "/trackers/#{id}/edit"
           when "status" then "/issue_statuses/#{id}/edit"
           when "priority", "activity" then "/enumerations/#{id}/edit"
           when "issue_tracking", "issue_hierarchy", "issue_watchers", "issue_custom_fields" then issue_path(id)
           when "time_tracking" then edit_time_entry_path(id)
           when "issue_attachments", "wiki_attachments" then "/attachments/#{id}"
           when "project_versions" then version_path(id)
           when "issue_categories" then "/projects/#{@project.identifier}/issue_categories/#{id}/edit"
           when "issue_journals", "issue_relation_notes"
             return id.to_s unless local_issue_id
             "#{issue_path(local_issue_id)}#change-#{id}"
           when "issue_relations"
             return id.to_s unless local_issue_id
             "#{issue_path(local_issue_id)}#relations"
           else
             # External adapters and their reference tables provide their own routes.
             extension = mirror_extension(module_key)
             extension&.local_path(id, @project) or return id.to_s
           end
    if source_url
      base = URI.parse(source_url)
      return id.to_s unless %w[http https].include?(base.scheme) && base.host && !base.userinfo
      # The isolated demo API hostname is only resolvable inside Docker.
      if ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && %w[source gateway].include?(base.host)
        base = URI.parse("http://localhost:3101")
      end
      remote_path = case module_key
                    when "user", "users" then "users/#{id}"
                    when "custom_field" then "custom_fields/#{id}/edit"
                    when "tracker" then "trackers/#{id}/edit"
                    when "status" then "issue_statuses/#{id}/edit"
                    when "priority", "activity" then "enumerations/#{id}/edit"
                    when "issue_tracking", "issue_hierarchy", "issue_watchers", "issue_custom_fields" then "issues/#{id}"
                    when "issue_attachments", "wiki_attachments" then "attachments/#{id}"
                    when "project_versions" then "versions/#{id}"
                    when "issue_categories"
                      setting = @setting || @project.mirror_project_setting
                      "projects/#{setting.source_project_id}/issue_categories/#{id}/edit"
                    when "issue_journals", "issue_relation_notes", "issue_relations"
                      return id.to_s unless remote_issue_id
                      anchor = module_key == "issue_relations" ? "relations" : "change-#{id}"
                      "issues/#{remote_issue_id}##{anchor}"
                    when "time_tracking" then "time_entries/#{id}/edit"
                    else mirror_extension(module_key)&.remote_path(id, @setting || @project.mirror_project_setting) or return id.to_s
                    end
      path = "#{base.to_s.sub(%r{/+\z}, '')}/#{remote_path}"
    end
    link_to id, path
  rescue ArgumentError, URI::InvalidURIError
    id.to_s
  end
end
