# frozen_string_literal: true
# File: redmine_mirror/db/migrate/020_add_mirror_run_stop_request.rb
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

class AddMirrorRunStopRequest < ActiveRecord::Migration[RedmineMirror.migration_version]
  # A running execution stopped from the Mirror page: the worker reads the request
  # between two objects, or the next tick ends it when its worker has stopped.
  def change
    add_column :mirror_sync_runs, :stop_requested_at, :datetime
    add_column :mirror_sync_runs, :stop_requested_by_id, :integer
  end
end
