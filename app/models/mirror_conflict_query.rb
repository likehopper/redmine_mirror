# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_conflict_query.rb
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
# Conflicts of one project as a Redmine query: filters, columns, sorting and grouping.

class MirrorConflictQuery < Query
  self.queried_class = MirrorConflict

  # Statuses and modules are stored as keys: rows and groups show their labels.
  class LabelColumn < QueryColumn
    def initialize(name, options = {})
      super
      @label = options.fetch(:label)
    end

    def label_for(key)
      @label.call(key)
    end

    def value_object(object)
      label_for(object.public_send(name))
    end

    def value(object)
      value_object(object)
    end
  end

  T = "mirror_conflicts"

  self.available_columns = [
    LabelColumn.new(:module_key, sortable: "#{T}.module_key", groupable: true, caption: :label_mirror_modules,
      label: ->(key) { ::I18n.t("label_mirror_module_#{key}", default: key.to_s) }),
    QueryColumn.new(:source_id, sortable: "#{T}.source_id", caption: :label_mirror_remote_id),
    QueryColumn.new(:destination_id, sortable: "#{T}.destination_id", caption: :label_mirror_local_id),
    LabelColumn.new(:status, sortable: "#{T}.status", groupable: true, caption: :field_status,
      label: ->(status) { ::I18n.t("label_mirror_conflict_#{status}", default: status.to_s) }),
    QueryColumn.new(:message, caption: :label_mirror_reason),
    TimestampQueryColumn.new(:created_at, sortable: "#{T}.created_at", default_order: "desc", groupable: true, caption: :label_mirror_conflict_detected_on),
    TimestampQueryColumn.new(:checked_at, sortable: "#{T}.checked_at", default_order: "desc", groupable: true, caption: :label_mirror_conflict_checked_on),
    QueryColumn.new(:resolved_by, sortable: -> { User.fields_for_order_statement("mirror_resolvers") }, groupable: true, caption: :label_mirror_conflict_resolved_by)
  ].freeze

  def initialize(attributes = nil, *args)
    super(attributes)
    # Open conflicts are the ones to handle.
    self.filters ||= { "status" => { operator: "=", values: ["open"] } }
  end

  def initialize_available_filters
    add_available_filter "status", type: :list, values: MirrorConflict::STATUSES.map { |status| [l("label_mirror_conflict_#{status}"), status] }
    add_available_filter "module_key", name: l(:label_mirror_modules), type: :list,
      values: -> { project_conflicts.distinct.pluck(:module_key).sort.map { |key| [l("label_mirror_module_#{key}", default: key), key] } }
    add_available_filter "source_id", name: l(:label_mirror_remote_id), type: :integer
    add_available_filter "destination_id", name: l(:label_mirror_local_id), type: :integer
    add_available_filter "message", name: l(:label_mirror_reason), type: :text
    add_available_filter "created_at", name: l(:label_mirror_conflict_detected_on), type: :date_past
    add_available_filter "checked_at", name: l(:label_mirror_conflict_checked_on), type: :date_past
    add_available_filter "resolved_by_id", name: l(:label_mirror_conflict_resolved_by), type: :list_optional,
      values: -> { User.where(id: project_conflicts.where.not(resolved_by_id: nil).select(:resolved_by_id)).sorted.map { |user| [user.name, user.id.to_s] } }
  end

  def available_columns
    self.class.available_columns
  end

  def default_columns_names
    @default_columns_names ||= %i[module_key source_id destination_id status message created_at checked_at]
  end

  def default_sort_criteria
    [["checked_at", "desc"]]
  end

  # Conflicts belong to one project; subprojects keep their own Mirror configuration.
  def project_statement
    project ? "#{T}.project_id = #{project.id.to_i}" : "1=0"
  end

  def base_scope
    MirrorConflict.where(statement)
  end

  def results(offset: nil, limit: nil)
    order = [group_by_sort_order, sort_clause, "#{T}.id DESC"].flatten.reject(&:blank?)
    base_scope.joins("LEFT OUTER JOIN users mirror_resolvers ON mirror_resolvers.id = #{T}.resolved_by_id")
      .preload(:resolved_by).order(order).offset(offset).limit(limit).to_a
  rescue ::ActiveRecord::StatementInvalid => error
    raise StatementInvalid, error.message
  end

  # SQL group keys are the stored keys; the rows display their labels.
  def grouped_query(&block)
    result = super
    column = group_by_column
    result && column.is_a?(LabelColumn) ? result.transform_keys { |key| column.label_for(key) } : result
  end

  def sql_for_resolved_by_id_field(field, operator, values)
    sql_for_field(field, operator, values, T, "resolved_by_id")
  end

  private

  def project_conflicts
    project ? project.mirror_conflicts : MirrorConflict.none
  end
end
