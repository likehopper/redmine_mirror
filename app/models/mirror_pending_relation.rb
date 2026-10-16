# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_pending_relation.rb
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
# Keep unresolved or blocked relations visible until both endpoints are available.

class MirrorPendingRelation < ActiveRecord::Base
  belongs_to :project
  validates :status, inclusion: { in: %w[pending blocked] }
end
