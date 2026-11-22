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
# Read the source changes after this destination's position. The destination keeps that
# position and its failures (mirror_sync_retries): the source stores nothing for it.

module RedmineMirror
  class ChangeSet
    attr_reader :cursor, :changes, :journaled_modules

    # Without a position, the source answers with the one to keep after a complete pass.
    def self.read(client, project_id, after:)
      params = after.nil? ? {} : { "after" => Integer(after) }
      changes = []
      journaled_modules = []
      loop do
        page = client.get("projects/#{Integer(project_id)}/mirror/source/changes.json", params)
        return new(cursor: page.fetch("cursor"), changes: [], full_required: true) if page.fetch("full_required")
        changes.concat(page.fetch("changes"))
        journaled_modules = Array(page["journaled_modules"]).map(&:to_s)
        cursor = Integer(page.fetch("cursor"))
        return new(cursor: cursor, changes: changes, full_required: false, journaled_modules: journaled_modules) if cursor >= Integer(page.fetch("high_water"))
        params = { "after" => cursor }
      end
    # 404: a source without the journal, or with it suspended. 422: a source up to
    # 1.0.0-beta.50, which requires the consumer key it no longer gets. Both leave the
    # destination in its compatible mode until the source is upgraded. A source that refuses
    # the feed to this account or project leaves it there too: complete, filtered reads.
    rescue Error => error
      unavailable = error.message.match?(/HTTP (404|422)/) && error.message.include?("mirror/source/changes")
      restricted = error.message.include?("Mirror source: incremental_visibility")
      module_disabled = error.message.include?("Mirror source: module")
      raise unless unavailable || restricted || module_disabled
      new(cursor: 0, changes: [], full_required: true, supported: false)
    end

    def initialize(cursor:, changes:, full_required:, supported: true, journaled_modules: [])
      @cursor = Integer(cursor)
      @journaled_modules = journaled_modules
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
