# frozen_string_literal: true
# File: redmine_mirror/test/compatibility/member_mapping_upgrade.rb
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
# Verify populated membership mapping upgrades in an empty disposable database.

abort "An empty disposable test database is required" unless Rails.env.test? &&
  ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && MirrorMapping.count.zero?

require Rails.root.join("plugins/redmine_mirror/db/migrate/023_allow_shared_member_destinations")
connection = ActiveRecord::Base.connection
key = "migration-member-aliases-check"
migration = AllowSharedMemberDestinations.new
migration.migrate(:down)
connection.execute <<~SQL
  INSERT INTO mirror_mappings
    (connection_key, module_key, source_id, destination_id, source_fingerprint,
     destination_fingerprint, created_at, updated_at)
  VALUES
    ('#{key}', 'project_members', 500, 900, 'source', 'destination', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
    ('#{key}', 'issue_tracking', 501, 901, 'source', 'destination', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
SQL
migration.migrate(:up)
MirrorMapping.reset_column_information
member = MirrorMapping.find_by!(connection_key: key, module_key: "project_members")
other = MirrorMapping.find_by!(connection_key: key, module_key: "issue_tracking")
raise "Backfill lost member scope" unless member.destination_scope == 500
raise "Other module uniqueness changed" unless other.destination_scope.zero?
alias_row = member.dup
alias_row.source_id = 502
alias_row.save!
begin
  migration.migrate(:down)
  raise "Downgrade should refuse shared correspondences"
rescue ActiveRecord::IrreversibleMigration
  raise "Downgrade damaged schema" unless connection.column_exists?(:mirror_mappings, :destination_scope)
end
alias_row.destroy!
migration.migrate(:down)
migration.migrate(:up)
MirrorMapping.reset_column_information
raise "Upgrade/downgrade lost original rows" unless MirrorMapping.where(connection_key: key).count == 2
MirrorMapping.where(connection_key: key).delete_all
puts "PASS: populated upgrade, protected downgrade, lossless downgrade/reupgrade"
