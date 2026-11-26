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
  def mirror_source_session_params(row)
    { session: row.session_key, user_id: row.user_id, remote_ip: row.remote_ip, purpose: row.purpose || "-" }
  end

  # The Mirror page of the project menu: overview, history, attention and synchronized objects.
  # The conflicts query page, filtered on one status ("all": no filter).
  def mirror_conflicts_path(project, status = nil)
    return project_mirror_conflicts_path(project) unless status
    return project_mirror_conflicts_path(project, set_filter: 1, f: [""]) if status == "all"
    project_mirror_conflicts_path(project, set_filter: 1, f: ["status"], op: { status: "=" }, v: { status: [status] })
  end

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

  def prepare_mirror_configuration(project)
    @setting = project.mirror_project_setting || project.build_mirror_project_setting
    # A refused first connection comes back with what was typed, except the API key.
    typed = session.delete(:mirror_typed_connection)
    if !@setting.persisted? && typed.is_a?(Hash)
      @setting.source_url = typed["source_url"].to_s
      @setting.source_project_identifier = typed["source_project_id"].to_s
      @setting.source_text_format = typed["source_text_format"] if RedmineMirror::TextFormat::SOURCE_FORMATS.include?(typed["source_text_format"])
    end
    @adapters = @setting.persisted? ? @setting.adapters : []
    tabs = ["connection"] + (@setting.persisted? ? ["modules", "schedule"] + @adapters.map(&:key) : [])
    @mirror_tab = tabs.include?(params[:mirror_tab]) ? params[:mirror_tab] : "connection"
    @mapping_values = project.mirror_reference_mappings.to_h do |row|
      [[row.reference_type, row.source_id.to_s], row.mode == "existing" ? row.destination_id.to_s : row.mode]
    end
    # Correspondences saved from an administrator's default (doc/DEFAULT_MAPPINGS.md).
    @default_mappings = project.mirror_reference_mappings.where(from_default: true).pluck(:reference_type, :source_id).to_set { |kind, id| [kind, id.to_s] }
  end

  # Source references used by the project that have no correspondence yet, per module.
  def mirror_unmapped_counts(project, setting)
    return {} unless setting&.persisted?
    @mirror_unmapped_counts ||= begin
      catalog = setting.source_catalog
      mapped = project.mirror_reference_mappings.pluck(:reference_type, :source_id).map { |kind, id| [kind, id.to_s] }.to_set
      setting.adapters.each_with_object({}) do |adapter, counts|
        next if adapter.configuration_parent
        count = adapter.mapping_tables.sum do |table|
          next 0 if table.unused?(setting)
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
    # References read before stay usable while the worker reads them again (after a
    # configuration change or a synchronization meeting a new source value): the steps
    # already done do not go back to "to do" meanwhile.
    loaded = connected && setting.source_catalog_loaded?
    catalog = if !connected then :todo
              elsif setting.catalog_refreshing? then loaded ? :done : :waiting
              elsif setting.catalog_status == "failed" then :failed
              else :done
              end
    detail = if catalog == :failed then setting.catalog_error
             elsif catalog == :done && setting.catalog_refreshing? then l(:text_mirror_step_references_refreshing)
             end
    unmapped = mirror_unmapped_counts(project, setting)
    usable = catalog == :done || loaded
    mappings = usable && setting.selected_modules.any? && unmapped.empty? ? :done : :todo
    synchronized = connected && runs.where(apply: true).exists?
    [
      [:connection, connected ? :done : :todo, nil, mirror_configuration_path(project)],
      [:references, catalog, detail, mirror_configuration_path(project)],
      [:mappings, mappings, unmapped.map { |key, count| "#{mirror_module_label(key)} #{count}" }.join(", ").presence,
        mirror_configuration_path(project, "modules")],
      [:sync, synchronized ? :done : :todo, nil, mirror_page_path(project)],
      [:schedule, connected && setting.auto_sync_enabled? ? :done : :todo, nil, mirror_configuration_path(project, "schedule")]
    ]
  end

  # Getting started is shown until a first synchronization succeeded.
  def mirror_setup_complete?(steps)
    steps.first(4).all? { |step| step[1] == :done }
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
    label += " - #{l(:status_registered)}" if user.registered?
    label
  end

  # "login · email · company" of a source user, when the source shares them (Mirror source).
  def mirror_source_user_details(info)
    info ? info.values_at("login", "mail", "company").reject(&:blank?).join(" · ") : ""
  end

  # Administration overview cells: the project links to its Mirror page, durations read
  # in hours and minutes; other cells use Redmine's query formatting.
  # A conflict row: objects link to both sides, the reason is shown translated.
  def mirror_conflict_column_content(column, conflict)
    case column.name
    when :source_id then mirror_object_link(conflict.module_key, conflict.source_id, source_url: @setting.source_url)
    when :destination_id then mirror_object_link(conflict.module_key, conflict.destination_id)
    when :message then mirror_reason_label(conflict.message)
    else column_content(column, conflict)
    end
  end

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

  # Live progress of a running execution (RunProgress): the module in progress, its
  # position and the share of modules done, counting the current one by its objects.
  def mirror_progress_summary(progress)
    modules = Array(progress["modules"])
    return nil if modules.empty?
    current_index = modules.index { |entry| entry["state"] == "running" }
    finished = modules.count { |entry| entry["state"] == "done" }
    current = current_index && modules[current_index]
    # A total exceeded by the objects handled is not that module's total (RunProgress).
    total = current && current["total"] && current["done"] <= current["total"] ? current["total"] : nil
    fraction = finished + (total && total.positive? ? current["done"].fdiv(total) : 0)
    { phase: progress["phase"], modules: modules, current: current, total: total,
      position: (current_index || finished.clamp(1, modules.size) - 1) + 1, count: modules.size,
      percentage: [(fraction * 100 / modules.size).floor, 99].min }
  end

  def mirror_duration(seconds)
    seconds = seconds.to_f.round
    return "0 s" if seconds.zero?
    hours, rest = seconds.divmod(3600)
    minutes, secs = rest.divmod(60)
    [("#{hours} h" if hours.positive?), ("#{minutes} min" if minutes.positive?), ("#{secs} s" if secs.positive? && hours.zero?)].compact.join(" ")
  end

  def mirror_module_duration(entry, run)
    seconds = entry["duration_seconds"]
    if seconds.nil? && entry["started_at"]
      end_time = run.status == "running" ? Time.current : run.finished_at
      seconds = [end_time.to_f - entry["started_at"].to_f, 0].max if end_time
    end
    seconds.nil? ? "—" : mirror_duration(seconds)
  end

  # Above this many rows, a mapping list is shown one page at a time: a source project can
  # share thousands of users. Saving only touches the rows the page shows.
  MIRROR_PAGINATION_THRESHOLD = 100

  # One page of rows and its Redmine paginator, or every row and nil when they are few.
  # A page past the end (rows saved out of the filter) falls back to the last one.
  def mirror_page_of(rows, param)
    return [rows, nil] if rows.size <= MIRROR_PAGINATION_THRESHOLD
    per_page = controller.per_page_option
    last_page = (rows.size + per_page - 1) / per_page
    paginator = Redmine::Pagination::Paginator.new(rows.size, per_page, params[param].to_i.clamp(1, last_page), param)
    [rows.slice(paginator.offset, per_page), paginator]
  end

  # Redmine's pagination links, kept on the Mirror tab of the project settings: that tab is
  # a path segment, which Redmine's own links drop.
  def mirror_pagination_links(paginator)
    content_tag(:span, class: "pagination") do
      pagination_links_full(paginator, paginator.item_count) do |text, parameters, options|
        query = request.query_parameters.merge(parameters.stringify_keys).compact.symbolize_keys
        link_to text, mirror_configuration_path(@project, nil, **query), options
      end
    end
  end

  # Whether a source reference matches the typed search (already downcased): its name or,
  # for users, the login, name, email and company the source shares.
  def mirror_reference_matches?(search, name, info)
    return true if search.empty?
    [name, *info&.values_at("login", "firstname", "lastname", "mail", "company")].any? { |text| text.to_s.downcase.include?(search) }
  end

  # The Users tab offers account creation when the source shares user details, or explains
  # why it does not to those who may create accounts (mirror_settings/_user_creation).
  def mirror_user_accounts_tab?(project, catalog)
    catalog.key?("user_details") || RedmineMirror.user_creation?(project)
  end

  # Unmapped source users with a shared (or hidden, to be typed) email that no local account
  # uses: the accounts a members manager may create, sorted by source name.
  def mirror_user_creation_candidates(project, catalog)
    @mirror_user_creation_candidates ||= begin
      mapped = project.mirror_reference_mappings.where(reference_type: "user").pluck(:source_id).map(&:to_s).to_set
      candidates = catalog.fetch("user_details", {}).select { |id, info| !mapped.include?(id) && (info["mail"].present? || info["mail_hidden"]) }
      shared = candidates.values.map { |info| info["mail"].to_s.downcase }.reject(&:empty?)
      taken = shared.empty? ? Set.new : EmailAddress.where("LOWER(address) IN (?)", shared).pluck(:address).map(&:downcase).to_set
      candidates.reject { |_, info| taken.include?(info["mail"].to_s.downcase) }.sort_by { |id, _| [catalog.fetch("user", {})[id].to_s.downcase, id.to_i] }
    end
  end

  # A single local reference with the same name, ignoring case, accents, punctuation and
  # word order. index: mirror_name_index of the table's choices.
  def mirror_name_suggestion(index, name, aliases = [])
    suggestions = ([name] + Array(aliases)).filter_map { |candidate| RedmineMirror::NameMatch.suggest(candidate, index) }.uniq
    suggestions.one? ? suggestions.first : nil
  end

  # The local choices indexed by name, once per table. Labels end with " (#id)" and, for
  # users, their login and email.
  def mirror_name_index(choices, type: nil, records: [])
    candidates = choices.select { |_, value| value.match?(/\A\d+\z/) }.map { |label, value| [label.sub(/ \(#\d+\)(?: .*)?\z/, ""), value] }
    candidates.concat(records.flat_map { |record| RedmineMirror::LocalizedNames.record_names(type, record).map { |name| [name, record.id.to_s] } }) if type
    RedmineMirror::NameMatch.index(candidates)
  end

  def mirror_reference_usage(catalog, type, id)
    usage = catalog.dig("#{type}_usage", id.to_s) || {}
    labels = []
    labels << l(:label_mirror_reference_current_usage, count: usage["current"].to_i) if usage["current"].to_i.positive?
    labels << l(:label_mirror_reference_history_usage, count: usage["history"].to_i) if usage["history"].to_i.positive?
    safe_join(labels, " · ") if labels.any?
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

  # Wiki, document and news files and news comments have their own correspondences, inside their module.
  MODULE_PARTS = { "wiki" => %w[wiki_attachments], "documents" => %w[document_attachments], "news" => %w[news_comments news_attachments] }.freeze

  def mirror_module_label(key)
    RedmineMirror::REGISTRY.keys.include?(key) || MODULE_PARTS.values.flatten.include?(key) ? l("label_mirror_module_#{key}".to_sym) : key
  end

  RUN_ACTIONS = %w[create update delete unchanged ignored note error].freeze

  # Top of a module tab: what the source holds against the objects linked here, the
  # last run that wrote the module, its open conflicts, and the correspondences of the
  # modules it relies on. Source figures come from the last reference refresh.
  def mirror_module_overview(project, setting, adapter)
    catalog = setting.source_catalog
    linked = setting.object_mappings.where(module_key: [adapter.key] + MODULE_PARTS.fetch(adapter.key, [])).group(:module_key).count
    run = project.mirror_sync_runs.where(apply: true, status: %w[succeeded partial failed]).for_module(adapter.key).order(id: :desc).first
    unmapped = mirror_unmapped_counts(project, setting)
    dependencies = setting.adapters.select do |entry|
      adapter.dependencies.include?(entry.key) && entry.mapping_tables.any? && entry.configuration_parent != adapter.key
    end
    { source: catalog.dig("module_statistics", adapter.key),
      read_at: catalog["read_at"] && Time.iso8601(catalog["read_at"]),
      linked: linked.fetch(adapter.key, 0),
      parts: MODULE_PARTS.fetch(adapter.key, []).to_h { |key| [key, linked.fetch(key, 0)] },
      run: run,
      actions: run ? run.log_entries.where(module_key: adapter.key).group(:action).count : {},
      conflicts: project.mirror_conflicts.where(module_key: adapter.key, status: "open").count,
      unmapped: unmapped[adapter.key].to_i,
      checks: adapter.overview_checks(project, setting, catalog.dig("module_statistics", adapter.key) || {}),
      dependencies: dependencies.map { |entry| [entry, unmapped[entry.key].to_i] } }
  end

  # A module check, with what fixes it when the user may act on it.
  def mirror_module_check(check)
    text = l(check.fetch(:key), **check.fetch(:args, {}).merge(count: check.fetch(:count)))
    link = case check[:link]
           when :admin_files then User.current.admin? && link_to(l(:label_mirror_fix_attachment_size), settings_path(tab: "attachments"))
           when :pending then link_to(l(:label_mirror_pending_links), mirror_page_path(@project, "attention", anchor: "mirror-pending-section"))
           end
    link ? safe_join([text, " ", link]) : text
  end

  # A source statistic: a byte count is shown as a size.
  def mirror_statistic_value(name, value)
    name == "bytes" ? number_to_human_size(value) : value
  end

  MAPPING_TABS = { "status" => "issue_tracking", "tracker" => "issue_tracking", "priority" => "issue_tracking",
    "user" => "users", "activity" => "time_tracking", "custom_field" => "issue_custom_fields",
    "role" => "project_members", "group" => "project_members", "document_category" => "documents" }.freeze

  # Run reasons are recorded in English, the language of logs and support requests.
  # Known forms are shown in the user's language; anything else, such as a message
  # written by the remote Redmine, is shown as recorded.
  MIRROR_REASON_FORMS = [
    [/\A(?<count>\d+) object\(s\) not synchronized; first: (?<first>.+)\z/m, :text_mirror_reason_run_errors],
    [/\A(?<reason>.+); the value was not imported\z/m, :text_mirror_reason_value_skipped],
    [/\A(?<reason>.+); the history change was not imported\z/m, :text_mirror_reason_history_skipped],
    [/\ARedmine API returned HTTP (?<status>\d+) for (?<request>[A-Z]+ \S+)(?<detail>.*)\z/m, :text_mirror_reason_http],
    [/\AMissing (?<kind>\w+) mapping for source ID (?<id>\d+)\z/, :text_mirror_reason_missing_mapping],
    [/\ALocal modification detected for (?<module>\w+) source ID (?<id>\d+)\z/, :text_mirror_reason_conflict],
    [/\A(?<original>Local modification detected for (?<module>\w+) source ID (?<id>\d+): the destination \w+ was (?:moved or )?deleted)\z/, :text_mirror_reason_conflict_deleted],
    [/\AMapped watcher cannot view destination issue\z/, :text_mirror_reason_watcher_no_access],
    [/\ASource custom field #(?<id>\d+) and destination field "(?<name>.+)" have incompatible formats or multiplicity\z/, :text_mirror_reason_field_incompatible],
    [/\ACustom field "(?<name>.+?)" is not enabled for destination tracker "(?<tracker>.*?)": enable it, or ignore source field #(?<id>\d+)\z/, :text_mirror_reason_field_not_on_tracker],
    [/\AThe destination custom field mapped to source field #(?<id>\d+) is not enabled in this project\z/, :text_mirror_reason_field_not_in_project],
    [/\AMissing value mapping for custom field source ID (?<id>\d+)\z/, :text_mirror_reason_missing_value_mapping],
    [/\AEnable the (?<project_module>\w+) module on the destination project\z/, :text_mirror_reason_project_module],
    [/\A(?<original>Missing (?:destination|owning) issue correspondence|Issue has no synchronized destination)\z/, :text_mirror_reason_issue_not_imported],
    [/\AParent wiki page "(?<title>.*)" is not imported\z/, :text_mirror_reason_wiki_parent_missing]
  ].freeze

  def mirror_reason_text(reason)
    text = reason.to_s
    MIRROR_REASON_FORMS.each do |pattern, key|
      match = pattern.match(text) or next
      values = match.named_captures.transform_keys(&:to_sym)
      values[:first] = mirror_reason_text(values[:first]) if values[:first]
      values[:reason] = mirror_reason_text(values[:reason]) if values[:reason]
      # Raw names keep the English text identical to the recorded one; labels serve other languages.
      values[:kind_label] = l("label_mirror_mapping_#{values[:kind]}", default: values[:kind]) if values[:kind]
      values[:module_label] = mirror_module_label(values[:module]) if values[:module]
      values[:project_module_label] = l_or_humanize(values[:project_module].downcase, prefix: "project_module_") if values[:project_module]
      return l(key, **values)
    end
    text
  end

  # The translated reason keeps the recorded text on hover, for support requests.
  def mirror_reason_label(reason)
    text = mirror_reason_text(reason)
    text == reason.to_s ? text : content_tag(:span, text, title: reason.to_s)
  end

  # An error or warning with, when known, the source reference name and a link to the
  # page that fixes it.
  def mirror_reason(reason, details = nil)
    text = reason.to_s
    name, label, path = mirror_fix(text, details)
    parts = [mirror_reason_label(text)]
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
      add.call(:label_mirror_fix_conflict, mirror_conflicts_path(@project))
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
    when "assignee_not_assignable", "watcher_no_access"
      guide[:name] = params["name"]
      guide[:text] = l("text_mirror_guide_#{code}".to_sym, name: params["name"] || l(:label_mirror_guide_unnamed_user))
      add.call(:label_mirror_add_member, User.current.allowed_to?(:manage_members, @project) && settings_project_path(@project, tab: "members"))
      add.call(:label_mirror_fix_mapping, manager && mirror_configuration_path(@project, "users"))
    when "repository_unreadable"
      guide[:text] = l(:text_mirror_guide_repository_unreadable)
      add.call(:label_mirror_fix_repository_paths, manager && mirror_configuration_path(@project, "repositories"))
    when "source_file_missing"
      guide[:text] = l(:text_mirror_guide_source_file_missing)
      add.call(:label_mirror_fix_missing_file, manager && mirror_configuration_path(@project, "issue_attachments"))
    when "issue_not_imported", "wiki_parent_missing"
      guide[:text] = l("text_mirror_guide_#{code}".to_sym)
    end
    # Nothing to ask for: a source permission or file, or objects that follow another fix.
    unless %w[source_permission source_file_missing issue_not_imported wiki_parent_missing].include?(code)
      guide[:text] = [guide[:text], l(:text_mirror_guide_ask)].compact.join(" ") if guide[:actions].empty?
    end
    guide
  end

  # A permission or a role visibility an account lacks on a Mirror source project.
  def mirror_source_gap_label(name)
    case name
    when :issues_visibility then "#{l(:field_issues_visibility)} : #{l(:label_issues_visibility_all)}"
    when :time_entries_visibility then "#{l_or_humanize(:time_entries_visibility, prefix: 'field_')} : #{l_or_humanize(:time_entries_visibility_all, prefix: 'label_')}"
    else l_or_humanize(name, prefix: "permission_")
    end
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
    mapped_keys = mapped.map { |row| [row.reference_type, row.source_id.to_s] }.to_set
    ai_config = MirrorAiConfig.current
    source_modules = catalog["source_modules"]
    checked_modules = []
    setting.adapters.each do |adapter|
      name = adapter.project_module
      if name && !checked_modules.include?(name)
        checked_modules << name
        label = l_or_humanize(name, prefix: "project_module_")
        source_name = adapter.source_project_module
        # Names the Mirror modules the button would unselect.
        modules = setting.adapters.select { |entry| entry.project_module == name && entry.configuration_parent.nil? }
        unselect = l(:button_mirror_unselect_named, modules: modules.map { |entry| l(entry.label) }.join(", "))
        if source_modules && source_name && !source_modules.include?(source_name.to_s)
          items << { text: l(:text_mirror_source_module_disabled, module: label), actions: [],
            buttons: [[unselect, { fix: "unselect_module", target: name }, manager]] }
        elsif !project.module_enabled?(name)
          # A button rather than a link to Redmine's modules tab, which does not come back here.
          items << { text: l(:text_mirror_project_module_disabled, module: label), actions: [],
            buttons: [[l(:button_mirror_enable_project_module_now), { fix: "enable_module", target: name }, User.current.allowed_to?(:select_project_modules, project)],
                      [unselect, { fix: "unselect_module", target: name }, manager]] }
        end
      end
      adapter.mapping_tables.each do |table|
        next if table.unused?(setting)
        next if table.respond_to?(:unmapped_allowed?) && table.unmapped_allowed?(setting)
        used = catalog["#{table.key}_used"]&.to_set
        missing = catalog.fetch(table.key, {}).select { |id, _| (used.nil? || used.include?(id)) && !mapped_keys.include?([table.key, id]) }
        next if missing.empty?
        tab = manager && mirror_configuration_path(project, MAPPING_TABS.fetch(table.key, adapter.key))
        actions = [[l(:label_mirror_fix_mapping), tab]]
        if ai_config.usable? && RedmineMirror::Ai.tables(ai_config).include?(table.key) && missing.size >= ai_config.min_references
          actions << [l(:button_mirror_ai_propose), tab]
        end
        items << { text: l(:text_mirror_check_unmapped, table: l(table.label), count: missing.size, names: missing.values.first(5).join(", ")), actions: actions }
        # Lazily: a users table can leave thousands of names unmapped, five are shown.
        missing.each_value.lazy.map { |name| mirror_near_miss(table.key, name) }.select(&:itself).first(5).each do |near|
          # A tracker or field to enable has a button, which comes back here.
          items << if near[:fix]
                     { text: near[:text], actions: [], buttons: [[l(:button_mirror_enable_project_module_now), near[:fix], near[:path]]] }
                   else
                     { text: near[:text], actions: [[l(near[:label]), near[:path]]] }
                   end
        end
      end
    end
    editor = User.current.allowed_to?(:edit_project, project)
    # Trackers the source issues use, mapped to a local tracker this project does not use.
    trackers = mapped.select { |row| row.reference_type == "tracker" && row.mode == "existing" && !project.tracker_ids.include?(row.destination_id) &&
      (catalog["tracker_used"].nil? || catalog["tracker_used"].include?(row.source_id.to_s)) }.map(&:destination_id)
    trackers = (trackers + RedmineMirror::DefaultMappings.disabled_default_trackers(setting)).uniq
    if trackers.any? && setting.selected_modules.include?("issue_tracking")
      items << { text: l(:text_mirror_trackers_disabled, names: Tracker.where(id: trackers).sorted.map(&:name).join(", ")),
        actions: [[l(:label_mirror_guide_enable_in_project), editor && settings_project_path(project, tab: "issues")]],
        buttons: [[l(:button_mirror_enable_trackers), { fix: "enable_trackers" }, editor]] }
    end
    # Fields mapped to a local field that this project does not use.
    if setting.selected_modules.include?("issue_custom_fields")
      enabled = project.all_issue_custom_fields.map(&:id)
      mapped.select { |row| row.reference_type == "custom_field" && row.mode == "existing" && !enabled.include?(row.destination_id) }.each do |row|
        field = IssueCustomField.find_by(id: row.destination_id)
        next unless field
        items << { text: l(:text_mirror_guide_field_disabled, name: field.name), actions: [],
          buttons: [[l(:button_mirror_enable_field), { fix: "enable_custom_field", target: field.id }, editor]] }
      end
    end
    # Anonymized users whose time entries have no account to go to.
    if setting.selected_modules.include?("time_tracking") && mapped.any? { |row| row.reference_type == "user" && row.mode == "anonymous" }
      own = setting.module_options.dig("users", "anonymous_user_id").presence
      default = RedmineMirror.default_anonymous_time_user_id
      if !own && (!default || !project.users.active.exists?(id: default))
        items << { text: l(default ? :text_mirror_time_user_not_member : :text_mirror_time_user_missing, name: User.find_by(id: default)&.name),
          actions: [[l(:label_mirror_fix_mapping), manager && mirror_configuration_path(project, "users")],
                    [l(:label_mirror_guide_add_member), default && User.current.allowed_to?(:manage_members, project) && settings_project_path(project, tab: "members")]] }
      end
    end
    # Data the source project has for a module not selected: members (when this project
    # lets the user manage them), categories and versions.
    catalog.fetch("source_inventory", {}).each do |key, count|
      adapter = RedmineMirror::REGISTRY[key]
      next unless count.to_i.positive? && adapter&.available? && !setting.selected_modules.include?(key)
      next if key == "project_members" && !User.current.allowed_to?(:manage_members, project)
      items << { text: l(:text_mirror_source_has_data, module: l(adapter.label), count: count), actions: [],
        buttons: [[l(:button_mirror_select_module), { fix: "select_module", target: key }, manager]] }
    end
    items.each do |item|
      item[:actions] = item[:actions].select(&:last).uniq(&:first)
      item[:buttons] = Array(item[:buttons]).select(&:last).map { |label, params, _| [label, params] }
    end
  end

  # Administration pages that create a missing local reference.
  MIRROR_CREATE_PATHS = { "tracker" => "/trackers/new", "status" => "/issue_statuses/new",
    "custom_field" => "/custom_fields/new?type=IssueCustomField", "priority" => "/enumerations/new?type=IssuePriority",
    "activity" => "/enumerations/new?type=TimeEntryActivity", "document_category" => "/enumerations/new?type=DocumentCategory" }.freeze

  # A local reference with the source name that exists in Redmine but is not offered in
  # this project's form, and how to make it available: {text:, label:, path:}.
  def mirror_near_miss(kind, name)
    return nil if name.blank?
    case kind
    when "tracker"
      tracker = mirror_namesake(kind, name) { Tracker.all.to_a }
      tracker && !@project.trackers.include?(tracker) &&
        { text: l(:text_mirror_guide_tracker_disabled, name: tracker.name), label: :label_mirror_guide_enable_in_project,
          path: User.current.allowed_to?(:edit_project, @project) && settings_project_path(@project, tab: "issues"),
          fix: { fix: "enable_tracker", target: tracker.id } }
    when "status"
      status = mirror_namesake(kind, name) { IssueStatus.all.to_a }
      status && !mirror_local_ids("status").include?(status.id) &&
        { text: l(:text_mirror_guide_status_no_workflow, name: status.name), label: :label_mirror_guide_edit_workflow,
          path: User.current.admin? && url_for(controller: "workflows", action: "edit") }
    when "custom_field"
      field = mirror_namesake(kind, name) { IssueCustomField.all.to_a }
      field && !@project.all_issue_custom_fields.include?(field) &&
        { text: l(:text_mirror_guide_field_disabled, name: field.name), label: :label_mirror_guide_enable_in_project,
          path: User.current.allowed_to?(:edit_project, @project) && settings_project_path(@project, tab: "issues"),
          fix: { fix: "enable_custom_field", target: field.id } }
    when "activity"
      activity = mirror_namesake(kind, name) { TimeEntryActivity.shared.to_a }
      activity && !@project.activities.include?(activity) &&
        { text: l(:text_mirror_guide_activity_inactive, name: activity.name), label: :label_mirror_guide_enable_in_project,
          path: User.current.allowed_to?(:manage_project_activities, @project) && settings_project_path(@project, tab: "activities") }
    when "priority"
      priority = mirror_namesake(kind, name) { IssuePriority.all.to_a }
      priority && !priority.active? &&
        { text: l(:text_mirror_guide_priority_inactive, name: priority.name), label: :label_mirror_guide_edit_enumeration,
          path: User.current.admin? && edit_enumeration_path(priority) }
    when "user"
      user = mirror_namesake(kind, name) { User.where(status: [User::STATUS_ACTIVE, User::STATUS_LOCKED, User::STATUS_REGISTERED]).to_a }
      user && !mirror_local_ids("user").include?(user.id) &&
        { text: l(:text_mirror_guide_user_not_member, name: user.name), label: :label_mirror_guide_add_member,
          path: User.current.allowed_to?(:manage_members, @project) && settings_project_path(@project, tab: "members") }
    end || nil
  end

  # The local record named like name, from an index built once per page and kind (the
  # block loads the candidates): a users table asks for thousands of names.
  def mirror_namesake(kind, name)
    @mirror_namesakes ||= {}
    index = @mirror_namesakes[kind] ||= yield.each_with_object({}) { |record, found| found[RedmineMirror::NameMatch.key(record.name)] ||= record }
    index[RedmineMirror::NameMatch.key(name)]
  end

  # Ids of the records this project's form offers for a mapping table, once per page.
  def mirror_local_ids(kind)
    @mirror_local_ids ||= {}
    @mirror_local_ids[kind] ||= RedmineMirror::MappingTable.new(kind).local_records(@project).pluck(:id).to_set
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

  # Objects a logged object belongs to: recorded since beta.59; older errors of issue
  # children only kept their source issue.
  def mirror_related_references(event)
    related = Array(event["related"]).select { |pair| pair.is_a?(Array) && pair.size == 2 && pair.last.is_a?(Integer) }
    related = [["issue_tracking", event["parent_id"]]] if related.empty? && event["parent_id"].is_a?(Integer)
    related
  end

  # The issue on both sides and the user as mapped here (name from the source otherwise).
  def mirror_related_links(event)
    links = mirror_related_references(event).map do |kind, id|
      case kind
      when "issue_tracking"
        local = @related_issues[id]
        source = link_to("##{id}", "#{@source_url.to_s.sub(%r{/+\z}, "")}/issues/#{id}", class: "external")
        safe_join([l(:label_issue), " ", source, (local ? safe_join([" → ", link_to("##{local}", issue_path(local))]) : nil)].compact)
      when "user"
        local = @related_users[id]
        name = local.is_a?(User) ? link_to_user(local) : (@setting.source_catalog.dig("user", id.to_s) || "##{id}")
        safe_join([l(:label_user), " ", name, (local.is_a?(String) ? " (#{l("label_mirror_related_user_#{local}", default: local)})" : nil)].compact)
      end
    end
    links.empty? ? "" : safe_join(links.compact, tag.br)
  end

  def mirror_object_link(module_key, id, source_url: nil, local_issue_id: nil)
    return "—" if id.blank?
    id = Integer(id)
    # Only notes and relations link through their local issue: a users table calls this
    # once per row.
    local_id = if %w[issue_journals issue_relation_notes issue_relations].include?(module_key)
                 source_url && @project ? MirrorMapping.find_by(project_id: @project.id, module_key: module_key, source_id: id)&.destination_id : id
               end
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
           when "issue_attachments", "wiki_attachments", "document_attachments", "news_attachments" then "/attachments/#{id}"
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
                    when "issue_attachments", "wiki_attachments", "document_attachments", "news_attachments" then "attachments/#{id}"
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
