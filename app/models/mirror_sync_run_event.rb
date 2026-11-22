# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_sync_run_event.rb
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
# One logged object of an execution. Module, IDs, action and reason are columns so that
# pages filter and count them in SQL; flags, warnings and error details stay in data.

class MirrorSyncRunEvent < ActiveRecord::Base
  belongs_to :run, class_name: "MirrorSyncRun"

  COLUMNS = %w[module source_id destination_id action reason].freeze

  # Only module/ID/action/reason and diagnostics are recorded, never payloads or API credentials.
  def self.attributes_for(run_id, event)
    event = event.transform_keys(&:to_s)
    data = event.except(*COLUMNS)
    { run_id: run_id, module_key: event["module"].to_s, source_id: event["source_id"]&.to_s,
      destination_id: event["destination_id"]&.to_s, action: event["action"].to_s,
      reason: event["reason"]&.to_s, data: data.empty? ? nil : JSON.generate(data) }
  end

  # The event as it was logged; a missing destination ID means the page looks it up.
  def to_event
    event = { "module" => module_key, "source_id" => identifier(source_id) }
    event["destination_id"] = identifier(destination_id) unless destination_id.nil?
    event["action"] = action
    event["reason"] = reason unless reason.nil?
    data.present? ? event.merge(JSON.parse(data)) : event
  end

  private

  def identifier(value)
    value&.match?(/\A\d+\z/) ? Integer(value) : value
  end
end
