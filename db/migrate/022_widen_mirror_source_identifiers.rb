# frozen_string_literal: true
# File: redmine_mirror/db/migrate/022_widen_mirror_source_identifiers.rb
#
# Redmine Mirror - modular project import and asynchronous replication.
# SPDX-License-Identifier: GPL-2.0-or-later

class WidenMirrorSourceIdentifiers < ActiveRecord::Migration[RedmineMirror.migration_version]
  def up
    change_column :mirror_source_changes, :source_id, :bigint, null: false
    change_column :mirror_source_changes, :parent_id, :bigint
    change_column :mirror_source_acknowledgements, :source_id, :bigint, null: false
    change_column :mirror_sync_retries, :source_id, :bigint, null: false
    change_column :mirror_sync_retries, :parent_id, :bigint
  end

  def down
    # A beta.46 runtime accepts bigint columns. Do not truncate identifiers that
    # already exceed 32 bits; migration 21 still drops the tables on uninstall.
  end
end
