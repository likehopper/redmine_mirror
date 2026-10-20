# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_source_access.rb
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
# One request a Mirror destination made to this source: served or refused, and what was sent.

class MirrorSourceAccess < ActiveRecord::Base
  ACTIONS = %w[list show download refused].freeze
  belongs_to :project
  belongs_to :user, optional: true
  validates :action, inclusion: { in: ACTIONS }
  # Aggregates selected by .sessions, cast like columns on every database.
  attribute :started_at, :datetime
  attribute :ended_at, :datetime
  %i[requests files documents refused].each { |name| attribute name, :integer }

  # One row per session (a destination run or reference refresh), newest first.
  def self.sessions
    select("project_id, session_key, MIN(created_at) AS started_at, MAX(created_at) AS ended_at, MIN(user_id) AS user_id, " \
           "MIN(remote_ip) AS remote_ip, MIN(purpose) AS purpose, COUNT(*) AS requests, SUM(bytes) AS bytes, " \
           "SUM(CASE WHEN action = 'download' THEN 1 ELSE 0 END) AS files, " \
           "SUM(CASE WHEN action = 'list' THEN object_count ELSE 0 END) AS documents, " \
           "SUM(CASE WHEN action = 'refused' THEN 1 ELSE 0 END) AS refused")
      .group(:project_id, :session_key).order(Arel.sql("MAX(created_at) DESC"))
  end

  def details
    JSON.parse(self[:details].presence || "{}")
  end
end
