# frozen_string_literal: true
# File: redmine_mirror/db/migrate/024_restrict_mirror_source_clients.rb
#
# Redmine Mirror - modular project import and asynchronous replication.
# SPDX-License-Identifier: GPL-2.0-or-later

class RestrictMirrorSourceClients < ActiveRecord::Migration[RedmineMirror.migration_version]
  def change
    add_column :mirror_source_settings, :client_addresses, :text
    add_column :mirror_source_settings, :authorized_user_ids, :text
    add_column :mirror_source_settings, :client_key_digest, :string, limit: 64
    add_column :mirror_project_settings, :encrypted_source_application_key, :text
    # beta50 details contain object titles, user names and filenames. Keep the audit
    # envelope (time, account, address, action, counts and bytes), but remove that
    # historical payload before the stricter viewer can expose it again.
    reversible do |direction|
      direction.up { execute "UPDATE mirror_source_accesses SET details = '{}'" }
    end
  end
end
