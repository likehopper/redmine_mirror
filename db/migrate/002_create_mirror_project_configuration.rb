# frozen_string_literal: true
# File: redmine_mirror/db/migrate/002_create_mirror_project_configuration.rb
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

class CreateMirrorProjectConfiguration < ActiveRecord::Migration[6.1]
  def change
    create_table :mirror_project_settings do |t|
      t.integer :project_id, null: false
      t.string :source_url
      t.bigint :source_project_id
      t.text :encrypted_api_key
      t.text :selected_modules
      t.text :source_catalog
      t.text :module_options
      t.timestamps
    end
    add_index :mirror_project_settings, :project_id, unique: true
    create_table :mirror_reference_mappings do |t|
      t.integer :project_id, null: false
      t.string :reference_type, null: false, limit: 64
      t.bigint :source_id, null: false
      t.bigint :destination_id
      t.string :mode, null: false, default: "existing", limit: 16
      t.timestamps
    end
    add_index :mirror_reference_mappings, [:project_id, :reference_type, :source_id],
      unique: true, name: "mirror_reference_mapping_unique"
    add_foreign_key :mirror_project_settings, :projects, on_delete: :cascade
    add_foreign_key :mirror_reference_mappings, :projects, on_delete: :cascade
  end
end
