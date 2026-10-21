# frozen_string_literal: true
# File: redmine_mirror/db/migrate/007_create_mirror_conflicts.rb
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

class CreateMirrorConflicts < ActiveRecord::Migration[RedmineMirror.migration_version]
  def change
    create_table :mirror_conflicts do |t|
      t.integer :project_id, null: false
      t.string :connection_key, null: false, limit: 64
      t.string :module_key, null: false
      t.integer :source_id, null: false
      t.integer :destination_id
      t.text :message
      t.string :status, null: false, default: "open"
      t.integer :resolved_by_id
      t.datetime :checked_at
      t.timestamps
    end
    add_index :mirror_conflicts, [:project_id, :connection_key, :module_key, :source_id], unique: true, name: "mirror_conflicts_identity"
  end
end
