# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_sync_run.rb
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
# Persist execution state, totals and filtered object-level events.

class MirrorSyncRun < ActiveRecord::Base
  belongs_to :project
  belongs_to :requested_by, class_name: "User", optional: true
  validates :status, inclusion: { in: %w[queued running succeeded partial failed cancelled] }
  validates :trigger, inclusion: { in: %w[manual automatic operator] }

  # partial: finished, but some objects failed and were skipped (on_error "skip").
  STATUSES = %w[queued running succeeded partial failed cancelled].freeze
  # A worker normally picks a run up within a minute; longer usually means none runs.
  QUEUE_WARNING_DELAY = 5.minutes

  def stalled_in_queue?(now = Time.current)
    status == "queued" && created_at && created_at < now - QUEUE_WARNING_DELAY
  end
  TRIGGERS = %w[manual automatic operator].freeze

  def progress_percentage
    return 100 if %w[succeeded partial].include?(status)
    return nil if total_records.nil?
    return 0 if total_records.zero?
    [processed_records * 100 / total_records, status == "running" ? 99 : 100].min
  end

  def module_counts
    self[:module_totals].present? ? JSON.parse(self[:module_totals]) : log_events.group_by { |event| event["module"] }.transform_values(&:size)
  end

  def log_events
    JSON.parse(self[:events].presence || "[]")
  end

  def append_event(event)
    # Only module/ID/action are recorded, never payloads or API credentials.
    update!(events: JSON.generate(log_events + [event]), processed_records: processed_records + 1)
  end
end
