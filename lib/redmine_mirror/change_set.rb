# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/change_set.rb
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
# Read source proposals without consuming them and acknowledge applied changes.

module RedmineMirror
  class ChangeSet
    attr_reader :cursor, :changes

    def self.read(client, project_id, consumer_key:)
      cursor = 0
      changes = []
      loop do
        page = client.get("projects/#{Integer(project_id)}/mirror/source/changes.json", "consumer" => consumer_key, "after" => cursor)
        return new(cursor: page.fetch("cursor"), changes: [], full_required: true) if page.fetch("full_required")
        changes.concat(page.fetch("changes"))
        cursor = Integer(page.fetch("cursor"))
        break if cursor >= Integer(page.fetch("high_water"))
      end
      new(cursor: cursor, changes: changes, full_required: false)
    rescue Error => error
      raise unless error.message.include?("HTTP 404") && error.message.include?("mirror/source/changes")
      new(cursor: 0, changes: [], full_required: true, supported: false)
    end

    def acknowledge(client, project_id, consumer_key:, changes: [], baseline: nil, pending: [])
      payload = { "consumer" => consumer_key, "changes" => changes.map { |change| change.slice("id", "module_key", "source_id") } }
      payload["baseline"] = baseline if baseline
      payload["pending"] = pending.map { |change| change.slice("module_key", "source_id", "parent_id") }
      client.create("projects/#{Integer(project_id)}/mirror/source/changes/acknowledgements.json", payload)
    end

    def initialize(cursor:, changes:, full_required:, supported: true)
      @cursor = Integer(cursor)
      @changes = changes
      @full_required = full_required
      @supported = supported
    end

    def full_required?
      @full_required
    end

    def supported?
      @supported
    end
  end
end
