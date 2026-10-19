# frozen_string_literal: true
# File: redmine_mirror/db/migrate/013_add_mirror_source_wins.rb
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
# Apply or revert this versioned Mirror database schema change.

class AddMirrorSourceWins < ActiveRecord::Migration[6.1]
  def change
    # Mirror mode: local differences are overwritten, local deletions recreated and
    # source deletions propagated. Off keeps the additive mode with conflicts.
    add_column :mirror_project_settings, :source_wins, :boolean, null: false, default: false
    # A run allowed to apply deletions beyond the per-module safety limit.
    add_column :mirror_sync_runs, :confirm_deletions, :boolean, null: false, default: false
  end
end
