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
          next 0 if table.respond_to?(:unmapped_allowed?) && table.unmapped_allowed?(setting)
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
  # "Name (#id) — login · email · company": the choice lists search all of them. Redmine's
  # rules apply: login for administrators, a hidden email for administrators only, the
  # company field when visible to the current user.
  def mirror_user_label(user, company = RedmineMirror.user_company_field)
    details = []
    details << user.login if User.current.admin? && user.login.present?
    details << user.mail if user.mail.present? && (User.current.admin? || !user.pref.hide_mail)
    if company && company.visible_by?(nil, User.current)
      value = user.custom_field_value(company)
      details << value if value.present?
    end
    label = "#{user.name} (##{user.id})"
    label += " — #{details.join(' · ')}" if details.any?
    label += " - #{l(:status_locked)}" if user.locked?
    label
  end

  # Administration overview cells: the project links to its Mirror page, durations read
  # in hours and minutes; other cells use Redmine's query formatting.
  def mirror_admin_column_content(column, setting)
    case column.name
    when :project
      link_to(setting.project.name, project_mirror_path(setting.project))
    when :last_run_duration, :duration_average
      minutes = column.value(setting)
      minutes.nil? ? "" : mirror_duration(minutes * 60)
    when :duration_total
      mirror_duration(setting["mirror_duration_seconds"].to_f)
    when :last_run_error
      content_tag(:span, truncate(setting["mirror_last_error"].to_s, length: 120), title: setting["mirror_last_error"].to_s)
    else
      column_content(column, setting)
    end
  end

  def mirror_duration(seconds)
    seconds = seconds.to_f.round
    return "0 s" if seconds.zero?
    hours, rest = seconds.divmod(3600)
    minutes, secs = rest.divmod(60)
    [("#{hours} h" if hours.positive?), ("#{minutes} min" if minutes.positive?), ("#{secs} s" if secs.positive? && hours.zero?)].compact.join(" ")
  end

  # A single local reference with the same name, ignoring case, accents, punctuation and
  # word order. index: mirror_name_index of the table's choices.
  def mirror_name_suggestion(index, name)
    RedmineMirror::NameMatch.suggest(name, index)
  end

  # The local choices indexed by name, once per table. Labels end with " (#id)" and, for
  # users, their login and email.
  def mirror_name_index(choices)
    candidates = choices.select { |_, value| value.match?(/\A\d+\z/) }.map { |label, value| [label.sub(/ \(#\d+\)(?: .*)?\z/, ""), value] }
    RedmineMirror::NameMatch.index(candidates)
  end

  # The AI proposal for an unmapped source reference, when it is still a valid choice.
  # ai: the "ai_suggestions" entry of the source catalog; labels: choice labels by value.
  def mirror_ai_suggestion(ai, labels, kind, source_id)
    proposal = ai.dig("tables", kind, source_id)
    proposal if proposal && labels.key?(proposal["id"].to_s)
  end

  # What the "Propose with AI" button of a mapping table would ask (doc/AI.md), or nil
  # when it is not offered: AI unavailable, table not allowed, or few references left,
  # which are quicker to map by hand.
  def mirror_ai_offer(config, table, locals, catalog)
    return nil unless config.usable? && RedmineMirror::Ai.tables(config).include?(table.key) && mirror_manager?(@project)
    count = RedmineMirror::Ai.pending_sources(@setting, table, catalog: catalog, locals: locals).size
    return nil if count < config.min_references
    { count: count, requests: RedmineMirror::Ai.requests_for(count), left: config.budget_left }
  end
  # Name of a Redmine text formatting, as in the administration settings.
  def mirror_text_format_name(format)
    return "—" if format.blank?
    Redmine::WikiFormatting.formats_for_select.find { |_, name| name.to_s == format.to_s }&.first || format
  end

  def mirror_module_label(key)
    # Wiki and document attachments have their own correspondences, inside their module.
    RedmineMirror::REGISTRY.keys.include?(key) || %w[wiki_attachments document_attachments].include?(key) ? l("label_mirror_module_#{key}".to_sym) : key
  end

  MAPPING_TABS = { "status" => "issue_tracking", "tracker" => "issue_tracking", "priority" => "issue_tracking",
    "user" => "users", "activity" => "time_tracking", "custom_field" => "issue_custom_fields",
    "role" => "project_members", "group" => "project_members", "document_category" => "documents" }.freeze

  # An error or warning with, when known, the source reference name and a link to the
  # page that fixes it.
  def mirror_reason(reason, details = nil)
    text = reason.to_s
    name, label, path = mirror_fix(text, details)
    parts = [text]
    parts << " (#{name})" if name
    parts << " — " << link_to(label, path, class: "mirror-fix") if path
    safe_join(parts)
  end

  # [source reference name, link text, path] of the main fix of a known cause.
  def mirror_fix(text, details = nil)
    return [] unless @setting
    code, params = RedmineMirror::Diagnosis.cause(text, details)
    return [] unless code
    guide = mirror_guidance(code, params)
    label, path = guide[:actions].first
    [guide[:name], label, path]
  end

  # What a known cause means and how to fix it: {name:, text:, actions: [[label, path]]}.
  # Actions are links the current user may follow; otherwise the text says who can.
  def mirror_guidance(code, params)
    params ||= {}
    manager = mirror_manager?(@project)
    guide = { name: nil, text: nil, actions: [] }
    add = ->(label, path) { guide[:actions] << [label.is_a?(Symbol) ? l(label) : label, path] if path }
    case code
    when "missing_mapping"
      kind, id = params["kind"], params["id"]
      guide[:name] = @setting.source_catalog.dig(kind, id)
      table = @setting.mapping_tables.find { |entry| entry.key == kind }
      add.call(:label_mirror_fix_mapping, manager && MAPPING_TABS[kind] && mirror_configuration_path(@project, MAPPING_TABS[kind]))
      near = mirror_near_miss(kind, guide[:name])
      if near
        guide[:text] = near[:text]
        add.call(near[:label], near[:path])
      else
        guide[:text] = l(table&.ignore_allowed? ? :text_mirror_guide_missing_mapping_ignore : :text_mirror_guide_missing_mapping,
          name: guide[:name] || "##{id}")
        add.call(:label_mirror_guide_create, User.current.admin? && MIRROR_CREATE_PATHS[kind])
      end
    when "missing_reference"
      mirror_guide_reference(guide, params, manager, add)
    when "field_not_on_tracker"
      field = IssueCustomField.find_by(name: params["name"])
      guide[:text] = l(:text_mirror_guide_field_not_on_tracker, name: params["name"])
      add.call(:label_mirror_fix_field_trackers, User.current.admin? && field && edit_custom_field_path(field))
      add.call(:label_mirror_fix_ignore_field, manager && mirror_configuration_path(@project, "issue_custom_fields"))
    when "field_not_in_project"
      guide[:text] = l(:text_mirror_guide_field_not_in_project)
      add.call(:label_mirror_fix_project_fields, User.current.allowed_to?(:edit_project, @project) && settings_project_path(@project, tab: "issues"))
      add.call(:label_mirror_fix_ignore_field, manager && mirror_configuration_path(@project, "issue_custom_fields"))
    when "field_values"
      guide[:text] = l(:text_mirror_guide_field_values)
      add.call(:label_mirror_fix_mapping, manager && mirror_configuration_path(@project, "issue_custom_fields"))
    when "conflict"
      guide[:text] = l(:text_mirror_guide_conflict)
      add.call(:label_mirror_fix_conflict, mirror_page_path(@project, "conflicts"))
    when "attachment_size"
      guide[:text] = l(:text_mirror_guide_attachment_size)
      add.call(:label_mirror_fix_attachment_size, User.current.admin? && settings_path(tab: "attachments"))
    when "project_module"
      guide[:text] = l(:text_mirror_guide_project_module, module: l_or_humanize(params["module"], prefix: "project_module_"))
      add.call(:label_mirror_enable_project_module, User.current.allowed_to?(:select_project_modules, @project) && settings_project_path(@project, tab: "modules"))
    when "source_permission"
      guide[:text] = l(:text_mirror_guide_source_permission, path: params["path"])
    when "deletions"
      guide[:text] = l(:text_mirror_guide_deletions)
      add.call(:label_mirror_guide_overview, mirror_page_path(@project))
    end
    guide[:text] = [guide[:text], l(:text_mirror_guide_ask)].compact.join(" ") if guide[:actions].empty? && code != "source_permission"
    guide
  end

  # What to settle before a preview, found from the configuration alone: references
  # without correspondence (with those that only need enabling), disabled project modules
  # and mapped fields the project does not use. Each item: {text:, actions: [[label, path]]}.
  def mirror_checklist(project, setting)
    return [] unless setting&.persisted? && setting.catalog_status == "ready"
    items = []
    manager = mirror_manager?(project)
    catalog = setting.source_catalog
    mapped = project.mirror_reference_mappings.to_a
    ai_config = MirrorAiConfig.current
    setting.adapters.each do |adapter|
      if adapter.project_module && !project.module_enabled?(adapter.project_module)
        items << { text: l(:text_mirror_project_module_disabled, module: l_or_humanize(adapter.project_module, prefix: "project_module_")),
          actions: [[l(:label_mirror_enable_project_module), User.current.allowed_to?(:select_project_modules, project) && settings_project_path(project, tab: "modules")]] }
      end
      adapter.mapping_tables.each do |table|
        next if table.respond_to?(:unmapped_allowed?) && table.unmapped_allowed?(setting)
        used = catalog["#{table.key}_used"]
        missing = catalog.fetch(table.key, {}).select { |id, _| (used.nil? || used.include?(id)) && mapped.none? { |row| row.reference_type == table.key && row.source_id.to_s == id } }
        next if missing.empty?
        tab = manager && mirror_configuration_path(project, MAPPING_TABS.fetch(table.key, adapter.key))
        actions = [[l(:label_mirror_fix_mapping), tab]]
        if ai_config.usable? && RedmineMirror::Ai.tables(ai_config).include?(table.key) && missing.size >= ai_config.min_references
          actions << [l(:button_mirror_ai_propose), tab]
        end
        items << { text: l(:text_mirror_check_unmapped, table: l(table.label), count: missing.size, names: missing.values.first(5).join(", ")), actions: actions }
        missing.each_value.filter_map { |name| mirror_near_miss(table.key, name) }.first(5).each do |near|
          items << { text: near[:text], actions: [[l(near[:label]), near[:path]]] }
        end
      end
    end
    # Fields mapped to a local field that this project does not use.
    if setting.selected_modules.include?("issue_custom_fields")
      enabled = project.all_issue_custom_fields.map(&:id)
      mapped.select { |row| row.reference_type == "custom_field" && row.mode == "existing" && !enabled.include?(row.destination_id) }.each do |row|
        field = IssueCustomField.find_by(id: row.destination_id)
        next unless field
        items << { text: l(:text_mirror_guide_field_disabled, name: field.name),
          actions: [[l(:label_mirror_guide_enable_in_project), User.current.allowed_to?(:edit_project, project) && settings_project_path(project, tab: "issues")]] }
      end
    end
    items.each { |item| item[:actions] = item[:actions].select(&:last).uniq(&:first) }
  end

  # Administration pages that create a missing local reference.
  MIRROR_CREATE_PATHS = { "tracker" => "/trackers/new", "status" => "/issue_statuses/new",
    "custom_field" => "/custom_fields/new?type=IssueCustomField", "priority" => "/enumerations/new?type=IssuePriority",
    "activity" => "/enumerations/new?type=TimeEntryActivity", "document_category" => "/enumerations/new?type=DocumentCategory" }.freeze

  # A local reference with the source name that exists in Redmine but is not offered in
  # this project's form, and how to make it available: {text:, label:, path:}.
  def mirror_near_miss(kind, name)
    return nil if name.blank?
    same = ->(records) { records.find { |record| RedmineMirror::NameMatch.key(record.name) == RedmineMirror::NameMatch.key(name) } }
    case kind
    when "tracker"
      tracker = same.call(Tracker.all.to_a)
      tracker && !@project.trackers.include?(tracker) &&
        { text: l(:text_mirror_guide_tracker_disabled, name: tracker.name), label: :label_mirror_guide_enable_in_project,
          path: User.current.allowed_to?(:edit_project, @project) && settings_project_path(@project, tab: "issues") }
    when "status"
      status = same.call(IssueStatus.all.to_a)
      status && !RedmineMirror::MappingTable.new("status").local_records(@project).include?(status) &&
        { text: l(:text_mirror_guide_status_no_workflow, name: status.name), label: :label_mirror_guide_edit_workflow,
          path: User.current.admin? && url_for(controller: "workflows", action: "edit") }
    when "custom_field"
      field = same.call(IssueCustomField.all.to_a)
      field && !@project.all_issue_custom_fields.include?(field) &&
        { text: l(:text_mirror_guide_field_disabled, name: field.name), label: :label_mirror_guide_enable_in_project,
          path: User.current.allowed_to?(:edit_project, @project) && settings_project_path(@project, tab: "issues") }
    when "activity"
      activity = same.call(TimeEntryActivity.shared.to_a)
      activity && !@project.activities.include?(activity) &&
        { text: l(:text_mirror_guide_activity_inactive, name: activity.name), label: :label_mirror_guide_enable_in_project,
          path: User.current.allowed_to?(:manage_project_activities, @project) && settings_project_path(@project, tab: "activities") }
    when "priority"
      priority = same.call(IssuePriority.all.to_a)
      priority && !priority.active? &&
        { text: l(:text_mirror_guide_priority_inactive, name: priority.name), label: :label_mirror_guide_edit_enumeration,
          path: User.current.admin? && edit_enumeration_path(priority) }
    when "user"
      user = same.call(User.where(status: [User::STATUS_ACTIVE, User::STATUS_LOCKED]).to_a)
      user && !RedmineMirror::MappingTable.new("user").local_records(@project).include?(user) &&
        { text: l(:text_mirror_guide_user_not_member, name: user.name), label: :label_mirror_guide_add_member,
          path: User.current.allowed_to?(:manage_members, @project) && settings_project_path(@project, tab: "members") }
    end || nil
  end

  # A category or version the issue uses but Mirror has not imported. A version shared
  # by another source project is imported by the local project that mirrors it.
  def mirror_guide_reference(guide, params, manager, add)
    guide[:name] = params["name"].presence
    connection = manager && mirror_configuration_path(@project)
    if params["field"] == "category"
      guide[:text] = l(:text_mirror_guide_category, name: params["name"])
      add.call(:label_mirror_guide_select_module, connection)
    elsif params["owner_id"].blank?
      guide[:text] = l(:text_mirror_guide_version, name: params["name"])
      add.call(:label_mirror_guide_select_module, connection)
    elsif params["owner_id"].to_i == @setting.source_project_id
      guide[:text] = l(:text_mirror_guide_version_own, name: params["name"])
      add.call(:label_mirror_guide_select_module, connection)
    else
      other = MirrorProjectSetting.where(source_url: @setting.source_url, source_project_id: params["owner_id"].to_i).where.not(project_id: @project.id).first
      if other
        guide[:text] = l(:text_mirror_guide_version_shared, name: params["name"], owner: params["owner_name"], project: other.project.name)
        add.call(l(:label_mirror_guide_open_project, project: other.project.name),
          User.current.allowed_to?(:view_mirror, other.project) && mirror_page_path(other.project))
      else
        guide[:text] = l(:text_mirror_guide_version_unmirrored, name: params["name"], owner: params["owner_name"])
      end
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
           when "priority", "activity", "document_category" then "/enumerations/#{id}/edit"
           when "issue_tracking", "issue_hierarchy", "issue_watchers", "issue_custom_fields" then issue_path(id)
           when "time_tracking" then edit_time_entry_path(id)
           when "issue_attachments", "wiki_attachments", "document_attachments" then "/attachments/#{id}"
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
                    when "priority", "activity", "document_category" then "enumerations/#{id}/edit"
                    when "issue_tracking", "issue_hierarchy", "issue_watchers", "issue_custom_fields" then "issues/#{id}"
                    when "issue_attachments", "wiki_attachments", "document_attachments" then "attachments/#{id}"
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
