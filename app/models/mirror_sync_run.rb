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
  EVENT_PROGRESS_BATCH = 25
  belongs_to :project
  belongs_to :requested_by, class_name: "User", optional: true
  belongs_to :stop_requested_by, class_name: "User", optional: true
  # The journal: one row per logged object (migration 26).
  has_many :log_entries, class_name: "MirrorSyncRunEvent", foreign_key: :run_id, dependent: :delete_all
  validates :status, inclusion: { in: %w[queued running succeeded partial failed cancelled] }
  validates :trigger, inclusion: { in: %w[manual automatic operator parent recovery] }

  # partial: finished, but some objects failed and were skipped (on_error "skip").
  STATUSES = %w[queued running succeeded partial failed cancelled].freeze
  # A worker normally picks a run up within a minute; longer usually means none runs.
  QUEUE_WARNING_DELAY = 5.minutes

  # Runs that planned or logged objects of a module.
  scope :for_module, lambda { |module_key|
    key = sanitize_sql_like(JSON.generate(module_key), "!")
    where("module_totals LIKE :manifest ESCAPE '!' OR EXISTS (SELECT 1 FROM mirror_sync_run_events " \
      "WHERE mirror_sync_run_events.run_id = mirror_sync_runs.id AND mirror_sync_run_events.module_key = :module)",
      manifest: "%#{key}:%", module: module_key.to_s)
  }

  # Ends the run, with its duration in seconds when it started.
  def finish!(attributes)
    now = Time.current
    update!(attributes.merge(finished_at: now, duration_seconds: started_at && [(now - started_at).round, 0].max))
  end

  # Asked from the Mirror page while running: the worker stops after the object in progress.
  def stop_requested?
    status == "running" && stop_requested_at_value.present?
  end

  # Cancelled from the Mirror page while running, rather than withdrawn or failed.
  def stopped_on_request?
    status == "cancelled" && stop_requested_at_value.present?
  end

  private

  # Before migration 20 the column is missing: pages still render.
  def stop_requested_at_value
    has_attribute?(:stop_requested_at) ? stop_requested_at : nil
  end

  public

  def stalled_in_queue?(now = Time.current)
    status == "queued" && created_at && created_at < now - QUEUE_WARNING_DELAY
  end
  TRIGGERS = %w[manual automatic operator parent recovery].freeze

  def progress_percentage
    return 100 if %w[succeeded partial].include?(status)
    return nil if total_records.nil?
    return 0 if total_records.zero?
    [processed_records * 100 / total_records, status == "running" ? 99 : 100].min
  end

  def module_counts
    self[:module_totals].present? ? JSON.parse(self[:module_totals]) : module_event_counts
  end

  # Logged objects per module, with the given modules listed even without any object.
  def module_event_counts(module_keys = [])
    module_keys.to_h { |key| [key, 0] }.merge(log_entries.group(:module_key).count)
  end

  # Phase and per-module counters written by RunProgress while the run works.
  def live_progress
    JSON.parse((has_attribute?(:progress) && self[:progress]).presence || "{}")
  rescue JSON::ParserError
    {}
  end

  # The whole journal in memory: for small runs and exports; pages query log_entries.
  def log_events
    log_entries.order(:id).map(&:to_event)
  end

  def append_event(event)
    # Not through log_entries: the association would keep every created row in memory.
    MirrorSyncRunEvent.create!(MirrorSyncRunEvent.attributes_for(id, event))
    self.processed_records += 1
    flush_event_progress! if (processed_records % EVENT_PROGRESS_BATCH).zero?
  end

  # Persist live counters in batches; finish!/update! writes any remaining dirty count.
  def flush_event_progress!
    # updated_at doubles as the heartbeat read by end_abandoned_stops.
    update_columns(processed_records: processed_records, updated_at: Time.current)
  end
end
