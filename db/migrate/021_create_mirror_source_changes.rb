# frozen_string_literal: true
# File: redmine_mirror/db/migrate/021_create_mirror_source_changes.rb
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

class CreateMirrorSourceChanges < ActiveRecord::Migration[RedmineMirror.migration_version]
  def change
    create_table :mirror_source_changes do |t|
      t.integer :project_id, null: false
      t.string :module_key, null: false, limit: 64
      t.integer :source_id, null: false
      t.string :action, null: false, limit: 10
      t.integer :parent_id
      t.datetime :created_at, null: false
    end
    add_index :mirror_source_changes, [:project_id, :id]
    add_index :mirror_source_changes, :created_at

    create_table :mirror_source_change_states do |t|
      t.integer :project_id, null: false
      t.bigint :discarded_before_id, null: false, default: 0
      t.timestamps
    end
    add_index :mirror_source_change_states, :project_id, unique: true

    create_table :mirror_source_consumers do |t|
      t.integer :project_id, null: false
      t.string :consumer_key, null: false, limit: 64
      t.bigint :baseline_change_id, null: false, default: 0
      t.timestamps
    end
    add_index :mirror_source_consumers, [:project_id, :consumer_key], unique: true,
      name: "mirror_source_consumers_identity"

    create_table :mirror_source_acknowledgements do |t|
      t.integer :project_id, null: false
      t.string :consumer_key, null: false, limit: 64
      t.string :module_key, null: false, limit: 64
      t.integer :source_id, null: false
      t.bigint :change_id, null: false
      t.timestamps
    end
    add_index :mirror_source_acknowledgements, [:project_id, :consumer_key, :module_key, :source_id],
      unique: true, name: "mirror_source_acknowledgements_identity"

    add_column :mirror_project_settings, :source_change_cursor, :bigint
    add_column :mirror_project_settings, :incremental_signature, :string, limit: 64
    add_column :mirror_project_settings, :source_consumer_key, :string, limit: 64
    add_column :mirror_project_settings, :incremental_mapping_state, :text

    create_table :mirror_sync_retries do |t|
      t.integer :project_id, null: false
      t.string :connection_key, null: false, limit: 64
      t.string :module_key, null: false, limit: 64
      t.integer :source_id, null: false
      t.string :action, null: false, limit: 10, default: "upsert"
      t.integer :parent_id
      t.text :message
      t.timestamps
    end
    add_index :mirror_sync_retries, [:project_id, :connection_key, :module_key, :source_id],
      unique: true, name: "mirror_sync_retries_identity"

    add_column :mirror_sync_runs, :force_full, :boolean, null: false, default: false
  end
end
