# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_project_setting.rb
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
# Store encrypted connection settings and validated project-level adapter configuration.

class MirrorProjectSetting < ActiveRecord::Base
  SYNC_INTERVALS = [5, 15, 30, 60, 360, 1440].freeze
  validates :sync_interval_minutes, inclusion: { in: SYNC_INTERVALS }
  belongs_to :project
  validates :project_id, uniqueness: true
  validates :source_project_id, numericality: { only_integer: true, greater_than: 0 }
  validate :validate_connection

  # Persist the resolved dependency closure so forms, worker totals and execution
  # order describe the same enabled modules.
  # Modules whose adapter is no longer registered (plugin removed) are left out
  # so the configuration stays readable; unavailable_modules reports them.
  def selected_modules
    RedmineMirror::REGISTRY.resolve(stored_modules.select { |key| RedmineMirror::REGISTRY[key] }).map(&:key)
  end

  # Stored modules that cannot run on this destination. Runs are refused until
  # an administrator restores the owning plugin or deselects them.
  def unavailable_modules
    stored_modules.reject { |key| RedmineMirror::REGISTRY[key]&.available? } |
      adapters.reject(&:available?).map(&:key)
  end

  def selected_modules=(value)
    self[:selected_modules] = JSON.generate(RedmineMirror::REGISTRY.resolve(Array(value).reject(&:blank?)).map(&:key))
  end

  def source_catalog
    JSON.parse(self[:source_catalog].presence || "{}")
  end

  def source_catalog=(value)
    self[:source_catalog] = JSON.generate(value)
  end

  def module_options
    options = JSON.parse(self[:module_options].presence || "{}")
    # Preserve previously configured anonymous time accounts after extracting Users.
    options["users"] ||= options["time_tracking"] if options["time_tracking"]
    options
  end

  def module_options=(value)
    self[:module_options] = JSON.generate(value)
  end

  # The web process and worker must share Redmine’s configured cipher key.
  # Return plaintext only to the authenticated source client, never to a form.
  def api_key
    return nil if self[:encrypted_api_key].blank?
    raise RedmineMirror::Error, "Configure database_cipher_key in Redmine to use the stored API key" unless Redmine::Ciphering.cipher_key
    Redmine::Ciphering.decrypt_text(self[:encrypted_api_key])
  end

  def api_key=(value)
    raise RedmineMirror::Error, "Configure database_cipher_key in Redmine before saving an API key" unless Redmine::Ciphering.cipher_key
    self[:encrypted_api_key] = Redmine::Ciphering.encrypt_text(value)
  end

  def source_client
    RedmineMirror::Client.new(url: source_url, api_key: api_key,
      allow_http: ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable")
  end

  def adapters
    RedmineMirror::REGISTRY.resolve(selected_modules)
  end

  def mapping_tables
    adapters.flat_map(&:mapping_tables).uniq(&:key)
  end

  # Build an execution snapshot from project-owned reference mappings. Literal
  # anonymous/ignore modes remain distinct from a missing mapping.
  def synchronization_config(destination_url:)
    tables = project.mirror_reference_mappings.group_by(&:reference_type).transform_values do |rows|
      rows.to_h { |row| [row.source_id.to_s, row.mode == "existing" ? row.destination_id : row.mode] }
    end
    { "source_url" => source_url, "source_project_id" => source_project_id,
      "destination_url" => destination_url, "destination_project_id" => project_id,
      "allow_http" => ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable",
      "modules" => selected_modules, "mappings" => tables, "module_options" => module_options }
  end

  private

  def stored_modules
    JSON.parse(self[:selected_modules].presence || "[]")
  end

  def validate_connection
    errors.add(:base, "Select at least one module") if selected_modules.empty?
    errors.add(:base, "Unavailable modules: #{unavailable_modules.join(', ')}") if unavailable_modules.any?
    begin
      source_client
    rescue RedmineMirror::Error => error
      errors.add(:base, error.message)
    end
  end
end
