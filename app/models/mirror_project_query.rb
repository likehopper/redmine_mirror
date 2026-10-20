# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_project_query.rb
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
# Administration overview of the projects Mirror is configured in, as a Redmine query.

class MirrorProjectQuery < Query
  # Column labels are translated by the class-level lambdas below.
  extend Redmine::I18n
  self.queried_class = MirrorProjectSetting

  # A column whose display value, group value and SQL group keys share one label, so that
  # group counts and totals match the rows (raw keys differ across databases).
  class Column < QueryColumn
    def initialize(name, options = {})
      super
      @raw = options.fetch(:raw)
      @label = options[:label] || ->(value) { value }
      @group_sql = options[:group_sql]
    end

    def value(object)
      @label.call(@raw.call(object))
    end

    def value_object(object)
      value(object)
    end

    def group_by_statement
      @group_sql || super
    end

    # SQL group keys converted to the labels the rows display.
    def map_group_keys(result)
      result.each_with_object({}) { |(key, value), hash| hash[@label.call(key)] = value }
    end
  end

  S = "mirror_project_settings"
  R = "mirror_sync_runs"

  def self.yes_no(value)
    ActiveModel::Type::Boolean.new.cast(value) ? l(:general_text_Yes) : l(:general_text_No)
  end

  def self.translate(prefix)
    ->(value) { value.present? ? l("#{prefix}#{value}", default: value.to_s) : nil }
  end

  def self.projects_by_id(id)
    id.blank? ? nil : Project.find_by(id: id)
  end

  # Computed dates come back as text on some databases (SQLite); they are stored in UTC.
  def self.time(alias_name)
    lambda do |setting|
      value = setting[alias_name]
      value.is_a?(String) ? ActiveSupport::TimeZone["UTC"].parse(value) : value
    end
  end

  def self.integer(alias_name)
    ->(setting) { setting[alias_name].to_i }
  end

  def self.column(name, raw:, label: nil, sql: nil, sortable: sql, groupable: false, totalable: false, default_order: nil, caption: nil)
    Column.new(name, raw: raw, label: label, group_sql: (sql if groupable), sortable: sortable,
      groupable: groupable, totalable: totalable, default_order: default_order, caption: caption || :"label_mirror_admin_#{name}")
  end

  ROOT_SQL = "(SELECT mirror_roots.id FROM projects mirror_roots WHERE mirror_roots.lft <= projects.lft AND mirror_roots.rgt >= projects.rgt AND mirror_roots.parent_id IS NULL)"
  PROJECT_LABEL = ->(project) { project.is_a?(Project) ? project : projects_by_id(project) }

  self.available_columns = [
    column(:project, raw: ->(setting) { setting.project }, sortable: "projects.lft", caption: :field_project),
    column(:root_project, raw: ->(setting) { setting.project.root }, label: PROJECT_LABEL, sql: ROOT_SQL, groupable: true),
    column(:parent_project, raw: ->(setting) { setting.project.parent }, label: PROJECT_LABEL, sql: "projects.parent_id", groupable: true, caption: :field_parent),
    column(:project_status, raw: ->(setting) { setting.project.status }, sql: "projects.status", groupable: true,
      label: ->(status) { status.present? ? l({ 1 => :project_status_active, 5 => :project_status_closed, 9 => :project_status_archived }.fetch(status.to_i, :label_none)) : nil }),
    column(:source_url, raw: ->(setting) { setting.source_url }, sql: "#{S}.source_url", groupable: true),
    column(:source_project, raw: ->(setting) { setting.source_project_identifier.presence || setting.source_project_id }, sortable: "#{S}.source_project_identifier"),
    column(:modules, raw: ->(setting) { setting.selected_modules }, label: ->(keys) { Array(keys).map { |key| l("label_mirror_module_#{key}", default: key) }.join(", ") }),
    column(:source_wins, raw: ->(setting) { setting.source_wins? }, label: ->(value) { yes_no(value) }, sql: "#{S}.source_wins", groupable: true),
    column(:source_text_format, raw: ->(setting) { setting.source_text_format }, sql: "#{S}.source_text_format", groupable: true),
    column(:on_error, raw: ->(setting) { setting.on_error }, label: translate("label_mirror_on_error_"), sql: "#{S}.on_error", groupable: true),
    column(:auto_sync_enabled, raw: ->(setting) { setting.auto_sync_enabled? }, label: ->(value) { yes_no(value) }, sql: "#{S}.auto_sync_enabled", groupable: true),
    column(:sync_interval_minutes, raw: ->(setting) { setting.sync_interval_minutes }, sortable: "#{S}.sync_interval_minutes"),
    column(:next_sync_at, raw: ->(setting) { setting.auto_sync_enabled? ? setting.next_sync_at : nil }, sortable: "#{S}.next_sync_at"),
    column(:catalog_status, raw: ->(setting) { setting.catalog_status }, sql: "#{S}.catalog_status", groupable: true),
    column(:configured_on, raw: ->(setting) { setting.created_at }, sortable: "#{S}.created_at", default_order: "desc"),
    column(:activity, raw: ->(setting) { setting["mirror_active_status"] }, sql: "mirror_active_runs.status", groupable: true,
      label: ->(status) { status.present? ? l("label_mirror_run_#{status}") : l(:label_mirror_idle) }),
    column(:last_run_at, raw: time("mirror_last_run_at"), sortable: "mirror_run_stats.last_run_at", default_order: "desc"),
    column(:last_run_status, raw: ->(setting) { setting["mirror_last_status"] }, label: translate("label_mirror_run_"), sql: "mirror_last_runs.status", groupable: true),
    column(:last_run_mode, raw: ->(setting) { setting["mirror_last_apply"] }, sql: "mirror_last_runs.apply", groupable: true,
      label: ->(apply) { apply.nil? ? nil : l(ActiveModel::Type::Boolean.new.cast(apply) ? :label_mirror_admin_mode_apply : :label_mirror_admin_mode_preview) }),
    column(:last_run_duration, raw: ->(setting) { setting["mirror_last_duration"] }, label: ->(seconds) { seconds && (seconds.to_f / 60).round(2) }, sortable: "mirror_last_runs.duration_seconds"),
    column(:last_run_error, raw: ->(setting) { setting["mirror_last_error"] }),
    column(:last_success_at, raw: time("mirror_last_success_at"), sortable: "mirror_run_stats.last_success_at", default_order: "desc"),
    column(:runs_count, raw: integer("mirror_runs_count"), sortable: "mirror_run_stats.runs_count", totalable: true, default_order: "desc"),
    column(:runs_recent, raw: integer("mirror_runs_recent"), sortable: "mirror_run_stats.runs_recent", totalable: true, default_order: "desc"),
    column(:duration_total, raw: ->(setting) { (setting["mirror_duration_seconds"].to_f / 3600).round(2) }, sortable: "mirror_run_stats.duration_seconds", totalable: true, default_order: "desc"),
    column(:duration_average, raw: ->(setting) { setting["mirror_average_seconds"] && (setting["mirror_average_seconds"].to_f / 60).round(2) }, sortable: "mirror_run_stats.average_seconds", default_order: "desc"),
    column(:processed_total, raw: integer("mirror_processed_records"), sortable: "mirror_run_stats.processed_records", totalable: true, default_order: "desc"),
    column(:objects_count, raw: integer("mirror_objects_count"), sortable: "mirror_object_counts.objects_count", totalable: true, default_order: "desc"),
    column(:open_conflicts, raw: integer("mirror_open_conflicts"), sortable: "mirror_conflict_counts.open_conflicts", totalable: true, default_order: "desc"),
    column(:pending_links, raw: integer("mirror_pending_links"), sortable: "mirror_pending_counts.pending_links", totalable: true, default_order: "desc")
  ].freeze

  # Runs started within this window count in "runs_recent".
  RECENT_DAYS = 30

  def initialize(attributes = nil, *args)
    super(attributes)
    self.filters ||= {}
  end

  def initialize_available_filters
    add_available_filter "project_id", type: :list, values: -> { MirrorProjectSetting.joins(:project).order("projects.lft").map { |setting| [setting.project.name, setting.project_id.to_s] } }
    add_available_filter "source_url", name: l(:label_mirror_admin_source_url), type: :list, values: -> { MirrorProjectSetting.distinct.order(:source_url).pluck(:source_url).compact.map { |url| [url, url] } }
    add_available_filter "module", name: l(:label_mirror_admin_module), type: :list, values: -> { RedmineMirror::REGISTRY.keys.map { |key| [l("label_mirror_module_#{key}", default: key), key] } }
    yes_no = [[l(:general_text_Yes), "1"], [l(:general_text_No), "0"]]
    add_available_filter "source_wins", name: l(:label_mirror_admin_source_wins), type: :list, values: yes_no
    add_available_filter "auto_sync_enabled", name: l(:label_mirror_admin_auto_sync_enabled), type: :list, values: yes_no
    add_available_filter "on_error", name: l(:label_mirror_admin_on_error), type: :list, values: MirrorProjectSetting::ON_ERROR.map { |value| [l("label_mirror_on_error_#{value}"), value] }
    add_available_filter "activity", name: l(:label_mirror_admin_activity), type: :list, values: [[l(:label_mirror_run_running), "running"], [l(:label_mirror_run_queued), "queued"], [l(:label_mirror_idle), "idle"]]
    add_available_filter "last_run_status", name: l(:label_mirror_admin_last_run_status), type: :list, values: MirrorSyncRun::STATUSES.map { |status| [l("label_mirror_run_#{status}"), status] }
    add_available_filter "last_run_at", name: l(:label_mirror_admin_last_run_at), type: :date_past
    add_available_filter "runs_count", name: l(:label_mirror_admin_runs_count), type: :integer
    add_available_filter "open_conflicts", name: l(:label_mirror_admin_open_conflicts), type: :integer
  end

  def available_columns
    self.class.available_columns
  end

  def default_columns_names
    @default_columns_names ||= %i[project source_url modules source_wins auto_sync_enabled activity last_run_at last_run_status runs_count duration_total open_conflicts]
  end

  def default_totalable_names
    %i[runs_count duration_total]
  end

  def default_sort_criteria
    [["project", "asc"]]
  end

  def base_scope
    MirrorProjectSetting.joins(self.class.joins_sql).where(statement)
  end

  def results(offset: nil, limit: nil)
    order = [group_by_sort_order, sort_clause].flatten.reject(&:blank?)
    base_scope.select(self.class.select_sql).preload(project: :parent).order(order).offset(offset).limit(limit).to_a
  rescue ::ActiveRecord::StatementInvalid => error
    raise StatementInvalid, error.message
  end

  # Group keys of computed columns become the labels the rows display.
  def grouped_query(&block)
    result = super
    column = group_by_column
    result && column.is_a?(Column) ? column.map_group_keys(result) : result
  end

  def total_for_runs_count(scope); scope.sum("mirror_run_stats.runs_count"); end
  def total_for_runs_recent(scope); scope.sum("mirror_run_stats.runs_recent"); end
  def total_for_processed_total(scope); scope.sum("mirror_run_stats.processed_records"); end
  def total_for_objects_count(scope); scope.sum("mirror_object_counts.objects_count"); end
  def total_for_open_conflicts(scope); scope.sum("mirror_conflict_counts.open_conflicts"); end
  def total_for_pending_links(scope); scope.sum("mirror_pending_counts.pending_links"); end

  # Hours, as the column.
  def total_for_duration_total(scope)
    total = scope.sum("mirror_run_stats.duration_seconds")
    total.is_a?(Hash) ? total.transform_values { |seconds| (seconds.to_f / 3600).round(2) } : (total.to_f / 3600).round(2)
  end

  def sql_for_module_field(_field, operator, values)
    clauses = values.map { |key| self.class.sanitize("#{S}.selected_modules LIKE ?", "%#{JSON.generate(key.to_s)}%") }
    operator == "=" ? "(#{clauses.join(' OR ')})" : "NOT (#{clauses.join(' OR ')})"
  end

  def sql_for_source_wins_field(field, operator, values); boolean_sql("#{S}.source_wins", operator, values); end
  def sql_for_auto_sync_enabled_field(field, operator, values); boolean_sql("#{S}.auto_sync_enabled", operator, values); end

  def sql_for_activity_field(_field, operator, values)
    clauses = values.map { |value| value == "idle" ? "mirror_active_runs.status IS NULL" : self.class.sanitize("mirror_active_runs.status = ?", value) }
    operator == "=" ? "(#{clauses.join(' OR ')})" : "NOT (#{clauses.join(' OR ')})"
  end

  def sql_for_last_run_status_field(field, operator, values); sql_for_field(field, operator, values, "mirror_last_runs", "status"); end
  def sql_for_last_run_at_field(field, operator, values); sql_for_field(field, operator, values, "mirror_run_stats", "last_run_at"); end
  def sql_for_runs_count_field(field, operator, values); sql_for_field(field, operator, values, "mirror_run_stats", "runs_count"); end
  def sql_for_open_conflicts_field(field, operator, values); sql_for_field(field, operator, values, "mirror_conflict_counts", "open_conflicts"); end

  def self.sanitize(*condition)
    MirrorProjectSetting.send(:sanitize_sql_array, condition)
  end

  # One row per configured project; the statistics come from joined subqueries that every
  # supported database runs the same way.
  def self.joins_sql
    since = MirrorProjectSetting.connection.quote(RECENT_DAYS.days.ago)
    <<~SQL.squish
      INNER JOIN projects ON projects.id = #{S}.project_id
      LEFT OUTER JOIN (SELECT project_id, COUNT(*) AS runs_count,
        SUM(CASE WHEN started_at >= #{since} THEN 1 ELSE 0 END) AS runs_recent,
        SUM(duration_seconds) AS duration_seconds, AVG(duration_seconds) AS average_seconds,
        SUM(processed_records) AS processed_records, MAX(started_at) AS last_run_at,
        MAX(CASE WHEN status = 'succeeded' THEN finished_at END) AS last_success_at
        FROM #{R} WHERE started_at IS NOT NULL GROUP BY project_id) mirror_run_stats ON mirror_run_stats.project_id = #{S}.project_id
      LEFT OUTER JOIN #{R} mirror_last_runs ON mirror_last_runs.id =
        (SELECT MAX(id) FROM #{R} WHERE #{R}.project_id = #{S}.project_id AND #{R}.started_at IS NOT NULL)
      LEFT OUTER JOIN #{R} mirror_active_runs ON mirror_active_runs.id =
        (SELECT MAX(id) FROM #{R} WHERE #{R}.project_id = #{S}.project_id AND #{R}.status IN ('queued', 'running'))
      LEFT OUTER JOIN (SELECT project_id, COUNT(*) AS objects_count FROM mirror_mappings GROUP BY project_id) mirror_object_counts
        ON mirror_object_counts.project_id = #{S}.project_id
      LEFT OUTER JOIN (SELECT project_id, COUNT(*) AS open_conflicts FROM mirror_conflicts WHERE status = 'open' GROUP BY project_id) mirror_conflict_counts
        ON mirror_conflict_counts.project_id = #{S}.project_id
      LEFT OUTER JOIN (SELECT project_id, COUNT(*) AS pending_links FROM
        (SELECT project_id FROM mirror_pending_relations UNION ALL SELECT project_id FROM mirror_pending_parents) mirror_pending
        GROUP BY project_id) mirror_pending_counts ON mirror_pending_counts.project_id = #{S}.project_id
    SQL
  end

  def self.select_sql
    ["#{S}.*",
      "mirror_active_runs.status AS mirror_active_status",
      "mirror_run_stats.last_run_at AS mirror_last_run_at", "mirror_run_stats.last_success_at AS mirror_last_success_at",
      "mirror_run_stats.runs_count AS mirror_runs_count", "mirror_run_stats.runs_recent AS mirror_runs_recent",
      "mirror_run_stats.duration_seconds AS mirror_duration_seconds", "mirror_run_stats.average_seconds AS mirror_average_seconds",
      "mirror_run_stats.processed_records AS mirror_processed_records",
      "mirror_last_runs.status AS mirror_last_status", "mirror_last_runs.apply AS mirror_last_apply",
      "mirror_last_runs.duration_seconds AS mirror_last_duration", "mirror_last_runs.error_message AS mirror_last_error",
      "mirror_object_counts.objects_count AS mirror_objects_count", "mirror_conflict_counts.open_conflicts AS mirror_open_conflicts",
      "mirror_pending_counts.pending_links AS mirror_pending_links"]
  end

  private

  def boolean_sql(column, operator, values)
    connection = MirrorProjectSetting.connection
    wanted = values.map { |value| value == "1" ? connection.quoted_true : connection.quoted_false }
    "#{column} #{operator == '=' ? 'IN' : 'NOT IN'} (#{wanted.join(', ')})"
  end
end
