# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_reference_mapping.rb
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
# Validate source-reference selections against existing permitted local objects.

class MirrorReferenceMapping < ActiveRecord::Base
  belongs_to :project
  validates :source_id, numericality: { only_integer: true, greater_than: 0 }
  validates :mode, inclusion: { in: %w[existing anonymous ignore] }
  validates :destination_id, numericality: { only_integer: true, greater_than: 0 }, if: -> { mode == "existing" }
  validates :source_id, uniqueness: { scope: [:project_id, :reference_type] }
  validate :validate_reference

  private

  def validate_reference
    setting = project.mirror_project_setting
    table = setting && setting.mapping_tables.find { |entry| entry.key == reference_type }
    unless table && setting.source_catalog.fetch(reference_type, {}).key?(source_id.to_s)
      errors.add(:base, "Unknown source reference")
      return
    end
    if mode == "ignore"
      errors.add(:base, "Ignoring is only supported for custom fields") unless table.ignore_allowed?
      errors.add(:destination_id, :invalid) unless destination_id.nil?
    elsif mode == "anonymous"
      errors.add(:base, "Anonymization is only supported for users") unless table.anonymous_allowed?
      errors.add(:destination_id, :invalid) unless destination_id.nil?
    elsif !table.local_records(project).any? { |record| record.id == destination_id }
      errors.add(:destination_id, :invalid)
    end
  end
end
