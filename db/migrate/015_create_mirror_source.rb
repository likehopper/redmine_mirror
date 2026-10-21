# frozen_string_literal: true
# File: redmine_mirror/db/migrate/015_create_mirror_source.rb
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

class CreateMirrorSource < ActiveRecord::Migration[RedmineMirror.migration_version]
  # Mirror source: what each project shares with Mirror destinations, and every access.
  def change
    create_table :mirror_source_settings do |t|
      t.integer :project_id, null: false
      t.text :shared_modules
      t.timestamps
    end
    add_index :mirror_source_settings, :project_id, unique: true
    create_table :mirror_source_accesses do |t|
      t.integer :project_id, null: false
      t.integer :user_id
      t.string :session_key, null: false, limit: 32
      t.string :purpose, limit: 20
      t.string :remote_ip, limit: 45
      t.string :action, null: false, limit: 20
      t.string :reason, limit: 20
      t.integer :object_count, null: false, default: 0
      t.bigint :bytes, null: false, default: 0
      t.text :details
      t.datetime :created_at, null: false
    end
    add_index :mirror_source_accesses, [:project_id, :session_key]
    add_index :mirror_source_accesses, :created_at
  end
end
