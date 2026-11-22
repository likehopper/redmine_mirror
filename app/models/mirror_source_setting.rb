# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_source_setting.rb
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
# What a source project shares with Mirror destinations (Mirror source module).

class MirrorSourceSetting < ActiveRecord::Base
  CLIENT_COLUMNS = %w[client_addresses authorized_user_ids client_key_digest].freeze

  belongs_to :project
  validates :project_id, uniqueness: true
  validate :client_addresses_are_valid

  def shared_modules
    JSON.parse(self[:shared_modules].presence || "[]") & RedmineMirror::Source::KINDS
  end

  def shared_modules=(value)
    self[:shared_modules] = JSON.generate(Array(value).map(&:to_s) & RedmineMirror::Source::KINDS)
  end

  def client_addresses
    has_attribute?(:client_addresses) ? self[:client_addresses].to_s : ""
  end

  def client_addresses=(value)
    self[:client_addresses] = RedmineMirror::Source.address_entries(value).join("\n")
  end

  def authorized_user_ids
    return [] unless has_attribute?(:authorized_user_ids)
    JSON.parse(self[:authorized_user_ids].presence || "[]").map(&:to_i).select(&:positive?).uniq
  rescue JSON::ParserError
    []
  end

  def authorized_user_ids=(value)
    self[:authorized_user_ids] = JSON.generate(Array(value).map(&:to_i).select(&:positive?).uniq)
  end

  def client_address_allowed?(address)
    RedmineMirror::Source.address_in?(address, RedmineMirror::Source.address_entries(client_addresses))
  end

  def client_key=(value)
    self.client_key_digest = Digest::SHA256.hexdigest(value.to_s)
  end

  def client_key?
    client_key_digest.to_s.match?(/\A[0-9a-f]{64}\z/)
  end

  def client_key_matches?(value)
    return false unless client_key? && value.to_s.present?
    ActiveSupport::SecurityUtils.secure_compare(client_key_digest, Digest::SHA256.hexdigest(value.to_s))
  end

  def self.client_schema_current?
    table_exists? && (CLIENT_COLUMNS - column_names).empty?
  end

  private

  def client_addresses_are_valid
    invalid = RedmineMirror::Source.address_entries(client_addresses).reject do |entry|
      IPAddr.new(entry)
      true
    rescue IPAddr::Error
      false
    end
    errors.add(:client_addresses, :invalid) if invalid.any?
  end
end
