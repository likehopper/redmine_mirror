# frozen_string_literal: true
# File: redmine_mirror/db/migrate/016_create_mirror_ai.rb
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

class CreateMirrorAi < ActiveRecord::Migration[RedmineMirror.migration_version]
  # AI proposals for the mappings (doc/AI.md): the instance configuration, the daily
  # usage, and each project's pending request.
  def change
    create_table :mirror_ai_configs do |t|
      t.boolean :enabled, null: false, default: false
      t.string :provider, null: false, default: "gemini", limit: 30
      t.string :url
      t.string :model
      t.text :encrypted_api_key
      t.boolean :send_user_names, null: false, default: false
      t.integer :min_references, null: false, default: 10
      t.integer :daily_request_limit, null: false, default: 50
      t.text :models_cache
      t.datetime :verified_at
      t.datetime :blocked_at
      t.string :blocked_reason
      t.timestamps
    end
    create_table :mirror_ai_usages do |t|
      t.date :day, null: false
      t.integer :requests, null: false, default: 0
      t.bigint :tokens, null: false, default: 0
    end
    add_index :mirror_ai_usages, :day, unique: true
    add_column :mirror_project_settings, :ai_status, :string, limit: 20
    add_column :mirror_project_settings, :ai_tables, :text
    add_column :mirror_project_settings, :ai_requested_by_id, :integer
    add_column :mirror_project_settings, :ai_requested_at, :datetime
    add_column :mirror_project_settings, :ai_error, :text
  end
end
