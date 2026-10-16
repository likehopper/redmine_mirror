# frozen_string_literal: true
# File: redmine_mirror/db/migrate/008_create_mirror_pending_parents.rb
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

class CreateMirrorPendingParents < ActiveRecord::Migration[6.1]
  def change
    create_table :mirror_pending_parents do |t|
      t.integer :project_id, null: false
      t.string :connection_key, null: false, limit: 64
      t.integer :source_id, null: false
      t.integer :local_issue_id
      t.integer :remote_parent_id, null: false
      t.string :status, null: false
      t.text :reason
      t.datetime :checked_at, null: false
    end
    add_index :mirror_pending_parents, [:project_id, :connection_key, :source_id], unique: true, name: "mirror_pending_parents_identity"
  end
end
