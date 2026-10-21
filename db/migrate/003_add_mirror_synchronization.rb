# frozen_string_literal: true
# File: redmine_mirror/db/migrate/003_add_mirror_synchronization.rb
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

class AddMirrorSynchronization < ActiveRecord::Migration[RedmineMirror.migration_version]
  def change
    add_column :mirror_project_settings, :auto_sync_enabled, :boolean, null: false, default: false
    add_column :mirror_project_settings, :sync_interval_minutes, :integer, null: false, default: 60
    add_column :mirror_project_settings, :next_sync_at, :datetime
    add_column :mirror_project_settings, :running_run_id, :bigint
    create_table :mirror_sync_runs do |t|
      t.integer :project_id, null: false
      t.integer :requested_by_id
      t.string :trigger, null: false
      t.boolean :apply, null: false, default: false
      t.string :status, null: false, default: "queued"
      t.datetime :started_at
      t.datetime :finished_at
      t.text :events
      t.string :error_message
      t.timestamps
    end
    add_index :mirror_sync_runs, [:project_id, :status]
    add_foreign_key :mirror_sync_runs, :projects, on_delete: :cascade
  end
end
