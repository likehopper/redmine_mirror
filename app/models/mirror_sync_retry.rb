# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_sync_retry.rb
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
# Destination-side failed object retained until a later synchronization succeeds.

class MirrorSyncRetry < ActiveRecord::Base
  belongs_to :project
  validates :module_key, format: { with: RedmineMirror::Registry::KEY_FORMAT }
  validates :source_id, numericality: { only_integer: true, greater_than: 0 }
  validates :action, inclusion: { in: MirrorSourceChange::ACTIONS }
end
