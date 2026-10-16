# frozen_string_literal: true
# File: redmine_mirror/db/migrate/005_add_mirror_object_mapping_context.rb
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

class AddMirrorObjectMappingContext < ActiveRecord::Migration[6.1]
  def change
    add_column :mirror_mappings, :project_id, :integer
    add_index :mirror_mappings, :project_id
    add_column :mirror_sync_runs, :source_url, :string
    add_column :mirror_sync_runs, :connection_key, :string, limit: 64
  end
end
