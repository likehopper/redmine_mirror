# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_conflict.rb
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
# Retain project-scoped divergence diagnostics and explicit exclusion decisions.

class MirrorConflict < ActiveRecord::Base
  belongs_to :project
  belongs_to :resolved_by, class_name: "User", optional: true
  validates :status, inclusion: { in: %w[open ignored resolved] }
  validates :source_id, numericality: { only_integer: true, greater_than: 0 }
end
