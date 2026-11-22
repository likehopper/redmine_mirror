# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/run_progress.rb
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
# Live progress of an execution for its page: the phase, then each module with its
# state, the source objects handled and, once the source has told it, their total.

module RedmineMirror
  class RunProgress
    # Seconds between two writes: the page reloads every few seconds, and one write per
    # object would double the database work of a large run.
    WRITE_INTERVAL = 2

    def initialize(run)
      @run = run
      @phase = nil
      @modules = {}
      @written_at = nil
    end

    # checking: objects are read and validated without writing; writing: objects are written.
    def phase!(phase)
      @phase = phase
      @modules.each_value { |entry| entry.merge!("state" => "waiting", "done" => 0) }
      write(force: true)
    end

    # The modules of the run, in their execution order.
    def modules!(keys)
      @modules = keys.to_h { |key| [key, { "state" => "waiting", "done" => 0, "total" => nil }] }
      write(force: true)
    end

    def start(key)
      @modules.each_value { |entry| entry["state"] = "done" if entry["state"] == "running" }
      entry = (@modules[key] ||= { "done" => 0, "total" => nil })
      entry.merge!("state" => "running", "done" => 0)
      write(force: true)
    end

    # The total the source gave with the first page of the module's list, or the exact
    # size of a list the adapter read completely.
    def total(key, count, exact: false)
      entry = @modules[key]
      entry["total"] = Integer(count) if entry && (exact || entry["total"].nil?)
    end

    def record(key)
      entry = @modules[key]
      return unless entry
      entry["done"] += 1
      write
    end

    def finish
      @modules.each_value { |entry| entry["state"] = "done" if entry["state"] == "running" }
      write(force: true)
    end

    def to_h
      { "phase" => @phase, "modules" => @modules.map { |key, entry| entry.merge("key" => key) } }
    end

    private

    def write(force: false)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if !force && @written_at && now - @written_at < WRITE_INTERVAL
      @written_at = now
      # updated_at doubles as the heartbeat read by end_abandoned_stops.
      @run.update_columns(progress: JSON.generate(to_h), updated_at: Time.now) if @run.has_attribute?(:progress)
    end
  end
end
