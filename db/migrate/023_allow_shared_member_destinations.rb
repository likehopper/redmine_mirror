# frozen_string_literal: true
# File: redmine_mirror/db/migrate/023_allow_shared_member_destinations.rb
#
# Redmine Mirror - modular project import and asynchronous replication.
# SPDX-License-Identifier: GPL-2.0-or-later

class AllowSharedMemberDestinations < ActiveRecord::Migration[RedmineMirror.migration_version]
  def up
    add_column :mirror_mappings, :destination_scope, :bigint, null: false, default: 0
    # Keep destination uniqueness for every other module on all supported databases.
    execute "UPDATE mirror_mappings SET destination_scope = source_id WHERE module_key = 'project_members'"
    remove_index :mirror_mappings, name: "mirror_mappings_destination_unique"
    add_index :mirror_mappings, [:connection_key, :module_key, :destination_id, :destination_scope],
      unique: true, name: "mirror_mappings_destination_unique"
  end

  def down
    duplicate = select_value("SELECT COUNT(*) FROM (SELECT 1 FROM mirror_mappings " \
      "GROUP BY connection_key, module_key, destination_id HAVING COUNT(*) > 1) shared_destinations")
    if duplicate.to_i.positive?
      raise ActiveRecord::IrreversibleMigration, "Shared member correspondences must be resolved before downgrading"
    end
    remove_index :mirror_mappings, name: "mirror_mappings_destination_unique"
    add_index :mirror_mappings, [:connection_key, :module_key, :destination_id],
      unique: true, name: "mirror_mappings_destination_unique"
    remove_column :mirror_mappings, :destination_scope
  end
end
