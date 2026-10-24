# frozen_string_literal: true
# File: redmine_mirror/db/migrate/017_create_mirror_default_mappings.rb
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

class CreateMirrorDefaultMappings < ActiveRecord::Migration[RedmineMirror.migration_version]
  # Default correspondences set by an administrator (doc/DEFAULT_MAPPINGS.md): a source
  # name, or none for the fallback, and its local reference or list value. They are saved
  # into each project when its source references are read, marked as coming from a default.
  def change
    create_table :mirror_default_mappings do |t|
      t.string :reference_type, null: false, limit: 64
      t.string :source_name
      t.string :source_key
      t.string :source_url
      t.integer :custom_field_id
      t.string :mode, null: false, default: "existing", limit: 16
      t.bigint :destination_id
      t.string :destination_value
      t.timestamps
    end
    add_index :mirror_default_mappings, [:reference_type, :source_key]
    add_foreign_key :mirror_default_mappings, :custom_fields, on_delete: :cascade
    add_column :mirror_reference_mappings, :from_default, :boolean, null: false, default: false
  end
end
