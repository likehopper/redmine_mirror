# frozen_string_literal: true
# File: redmine_mirror/db/migrate/024_index_mirror_source_access_sessions.rb
#
# Redmine Mirror - modular project import and asynchronous replication.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Index the access log by session: every Mirror source request looks its session up.

class IndexMirrorSourceAccessSessions < ActiveRecord::Migration[RedmineMirror.migration_version]
  def change
    add_index :mirror_source_accesses, :session_key
  end
end
