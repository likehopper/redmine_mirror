# frozen_string_literal: true
# File: redmine_mirror/db/migrate/025_drop_mirror_source_consumers.rb
#
# Redmine Mirror - modular project import and asynchronous replication.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Destinations keep their journal position and failures themselves: a source no longer
# stores consumers or acknowledgements, and a destination no longer needs a consumer key.

class DropMirrorSourceConsumers < ActiveRecord::Migration[RedmineMirror.migration_version]
  def up
    drop_table :mirror_source_acknowledgements if table_exists?(:mirror_source_acknowledgements)
    drop_table :mirror_source_consumers if table_exists?(:mirror_source_consumers)
    remove_column :mirror_project_settings, :source_consumer_key if column_exists?(:mirror_project_settings, :source_consumer_key)
  end

  # Restores empty tables: destinations then make one complete pass, as after a gap.
  def down
    add_column :mirror_project_settings, :source_consumer_key, :string, limit: 64
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
      t.bigint :source_id, null: false
      t.bigint :change_id, null: false
      t.timestamps
    end
    add_index :mirror_source_acknowledgements, [:project_id, :consumer_key, :module_key, :source_id],
      unique: true, name: "mirror_source_acknowledgements_identity"
  end
end
