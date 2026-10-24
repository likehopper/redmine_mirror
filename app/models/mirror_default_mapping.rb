# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_default_mapping.rb
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
# An administrator's default correspondence (doc/DEFAULT_MAPPINGS.md): a source name, or
# none for the fallback of its table, and a local reference or custom field list value.

class MirrorDefaultMapping < ActiveRecord::Base
  # Reference tables, in the order of the administration page. Users only take a
  # fallback: accounts are matched in each project. List values are per destination field.
  TYPES = %w[tracker status priority activity document_category role group custom_field user custom_field_value].freeze
  FALLBACK_ONLY = %w[user].freeze

  belongs_to :custom_field, optional: true
  validates :reference_type, inclusion: { in: TYPES }
  validates :mode, inclusion: { in: %w[existing anonymous ignore] }
  validates :source_name, length: { maximum: 255 }
  before_validation :normalize
  validate :validate_rule

  scope :sorted, -> { order(:reference_type, :custom_field_id, Arel.sql("CASE WHEN source_key IS NULL THEN 1 ELSE 0 END"), :source_key, :source_url) }

  def self.schema_current?
    table_exists? && MirrorReferenceMapping.column_names.include?("from_default")
  end

  # Local references an administrator may choose for a table, all projects together. The
  # project's own check (enabled tracker, field available) is made when a default is saved
  # into it.
  def self.destinations(type)
    case type
    when "tracker" then Tracker.sorted.to_a
    when "status" then IssueStatus.sorted.to_a
    when "priority" then IssuePriority.active.sorted.to_a
    when "activity" then TimeEntryActivity.shared.active.sorted.to_a
    when "document_category" then DocumentCategory.shared.active.sorted.to_a
    when "role" then Role.givable.sorted.to_a
    when "group" then Group.givable.sorted.to_a
    when "custom_field" then IssueCustomField.sorted.to_a
    when "user" then User.where(status: [User::STATUS_ACTIVE, User::STATUS_LOCKED]).sorted.to_a
    else []
    end
  end

  # Issue custom fields whose values are chosen in a list: their values take defaults.
  def self.list_fields
    IssueCustomField.where(field_format: %w[list enumeration]).sorted.to_a
  end

  # A list field's choices as [label, value]: list values are their own label, enumeration
  # values are IDs.
  def self.value_choices(field)
    field.possible_values_options.map { |label, id| [label.to_s, (id || label).to_s] }
  end

  # The mapping table of a reference type, for its special choices (ignore, anonymize).
  def self.table(type)
    RedmineMirror::REGISTRY.mapping_table(type)
  end

  def self.normalize_url(url)
    url.to_s.strip.sub(%r{/+\z}, "").presence
  end

  def fallback?
    source_key.nil?
  end

  def destination
    return nil unless mode == "existing" && destination_id
    self.class.destinations(reference_type).find { |record| record.id == destination_id }
  end

  # The destination as people read it: a name, a list value's label, or the special choice.
  def destination_label
    return destination_value_label if reference_type == "custom_field_value"
    return mode if mode != "existing"
    destination&.name
  end

  def destination_value_label
    return nil unless custom_field
    self.class.value_choices(custom_field).find { |_, value| value == destination_value.to_s }&.first
  end

  private

  def normalize
    self.source_name = source_name.to_s.strip.presence
    self.source_key = source_name && RedmineMirror::NameMatch.key(source_name).presence
    self.source_url = self.class.normalize_url(source_url)
    self.custom_field_id = nil unless reference_type == "custom_field_value"
  end

  def validate_rule
    errors.add(:source_name, :invalid) if source_name && source_key.nil?
    errors.add(:source_name, :present) if FALLBACK_ONLY.include?(reference_type) && source_name
    if reference_type == "custom_field_value"
      validate_value
    elsif TYPES.include?(reference_type)
      validate_reference
    end
    others = self.class.where(reference_type: reference_type, custom_field_id: custom_field_id, source_url: source_url, source_key: source_key)
    errors.add(:base, :taken) if others.where.not(id: id).exists?
  end

  def validate_value
    unless custom_field.is_a?(IssueCustomField) && %w[list enumeration].include?(custom_field.field_format)
      errors.add(:custom_field_id, :invalid)
      return
    end
    errors.add(:mode, :invalid) unless mode == "existing"
    errors.add(:destination_id, :invalid) unless destination_id.nil?
    errors.add(:destination_value, :invalid) unless destination_value_label
  end

  def validate_reference
    table = self.class.table(reference_type)
    errors.add(:destination_value, :invalid) unless destination_value.nil?
    case mode
    when "ignore"
      errors.add(:mode, :invalid) unless table&.ignore_allowed?
      errors.add(:destination_id, :invalid) unless destination_id.nil?
    when "anonymous"
      errors.add(:mode, :invalid) unless table&.anonymous_allowed?
      errors.add(:destination_id, :invalid) unless destination_id.nil?
    else
      errors.add(:destination_id, :invalid) unless destination
    end
  end
end
