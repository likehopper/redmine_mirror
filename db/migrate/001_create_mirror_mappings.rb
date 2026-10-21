# frozen_string_literal: true
# File: redmine_mirror/db/migrate/001_create_mirror_mappings.rb
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

class CreateMirrorMappings < ActiveRecord::Migration[RedmineMirror.migration_version]
  def change
    create_table :mirror_mappings do |t|
      t.string :connection_key, null: false, limit: 64
      t.string :module_key, null: false, limit: 64
      t.bigint :source_id, null: false
      t.bigint :destination_id, null: false
      t.string :source_fingerprint, null: false, limit: 64
      t.string :destination_fingerprint, null: false, limit: 64
      t.timestamps
    end
    add_index :mirror_mappings, [:connection_key, :module_key, :source_id],
              unique: true, name: "mirror_mappings_source_unique"
    add_index :mirror_mappings, [:connection_key, :module_key, :destination_id],
              unique: true, name: "mirror_mappings_destination_unique"
  end
end
