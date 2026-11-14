# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_source_change_state.rb
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
# Oldest discarded change boundary that makes a stale destination require a full pass.

class MirrorSourceChangeState < ActiveRecord::Base
  belongs_to :project
  validates :project_id, uniqueness: true
end
