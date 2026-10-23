# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/synchronization.rb
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
# Queue, lease and execute independent project runs with persisted progress and scheduling.

require "fileutils"

module RedmineMirror
  class Synchronization
    # Lock the project configuration so concurrent manual requests cannot queue
    # two imports before either worker has acquired the execution lease.
    def self.enqueue(setting, apply:, trigger:, user: nil, confirm_deletions: false)
      setting.with_lock do
        raise Error, "Mirror module is disabled" unless setting.project.module_enabled?(:mirror)
        raise Error, "Synchronization already queued or running" if setting.running_run_id || setting.project.mirror_sync_runs.where(status: %w[queued running]).exists?
        raise Error, "Unavailable modules: #{setting.unavailable_modules.join(', ')}" if setting.unavailable_modules.any?
        setting.project.mirror_sync_runs.create!(apply: apply, trigger: trigger, requested_by: user, confirm_deletions: apply && confirm_deletions,
          module_totals: JSON.generate(setting.selected_modules.to_h { |key| [key, 0] }))
      end
    end

    # Only a queued run can be withdrawn; the lock matches the worker's claim, so a run
    # is either cancelled here or started by a worker, never both.
    def self.cancel(run)
      run.project.mirror_project_setting.with_lock do
        run.reload
        raise Error, "Only a queued execution can be cancelled" unless run.status == "queued"
        run.update!(status: "cancelled", finished_at: Time.current)
      end
    end

    # Source references requested from the web UI, refreshed before any run so that a
    # preview queued right after a configuration change uses them.
    def self.refresh_catalogs
      MirrorProjectSetting.where(catalog_status: "pending").find_each do |setting|
        claimed = false
        setting.with_lock do
          next unless setting.catalog_status == "pending"
          setting.update_columns(catalog_status: "refreshing", catalog_progress: nil)
          claimed = true
        end
        next unless claimed
        begin
          client = setting.source_client(purpose: "references")
          # Progress is saved at most every 2 seconds, for the configuration page.
          saved_at = nil
          progress = lambda do |step, steps, key, records|
            next if saved_at && Time.current - saved_at < 2 && records.positive?
            saved_at = Time.current
            setting.update_columns(catalog_progress: JSON.generate("step" => step, "steps" => steps, "module" => key, "records" => records, "at" => saved_at.iso8601))
          end
          catalog = SourceCatalog.new(client: client, project_id: setting.source_project_id, adapters: setting.adapters).fetch(progress: progress)
          identifier = client.get("projects/#{Integer(setting.source_project_id)}.json").fetch("project")["identifier"]
          # AI proposals cost requests: keep them; the forms show only those still valid.
          previous = setting.reload.source_catalog["ai_suggestions"]
          catalog["ai_suggestions"] = previous if previous
          setting.update_columns(source_catalog: JSON.generate(catalog), source_project_identifier: identifier,
            catalog_status: "ready", catalog_error: nil, catalog_progress: nil, updated_at: Time.current)
        rescue StandardError => error
          # Unexpected exception text can contain URLs, credentials or private records.
          message = error.is_a?(Error) ? error.message : "Internal error (#{error.class.name})"
          setting.update_columns(catalog_status: "failed", catalog_error: message)
        end
      end
    end

    # Schedule only one due run per project; missed intervals do not accumulate
    # catch-up jobs. Each completed run calculates its next deadline.
    def self.tick
      refresh_catalogs
      # AI proposals asked for in the mapping forms (doc/AI.md).
      Ai.process_requests
      now = Time.current
      MirrorProjectSetting.where(auto_sync_enabled: true).where("next_sync_at IS NULL OR next_sync_at <= ?", now).find_each do |setting|
        setting.with_lock do
          next unless setting.auto_sync_enabled? && (setting.next_sync_at.nil? || setting.next_sync_at <= now)
          next unless setting.project.module_enabled?(:mirror)
          next if setting.running_run_id || setting.project.mirror_sync_runs.where(status: %w[queued running]).exists?
          setting.project.mirror_sync_runs.create!(apply: true, trigger: "automatic", module_totals: JSON.generate(setting.selected_modules.to_h { |key| [key, 0] }))
          setting.update_columns(next_sync_at: now + setting.sync_interval_minutes.minutes)
        end
      end
      MirrorSyncRun.where(status: "queued").find_each { |run| execute(run) }
    end

    # Claim the database lease before reading remote data. This guards project-mode
    # workers on different hosts; the file lock also coordinates legacy local tasks.
    def self.execute(run)
      setting = run.project.mirror_project_setting
      return unless setting
      acquired = false
      setting.with_lock do
        run.reload
        return unless run.status == "queued" && setting.running_run_id.nil?
        if run.trigger == "automatic" && !setting.auto_sync_enabled?
          run.update!(status: "cancelled", finished_at: Time.current)
          return
        end
        setting.update_columns(running_run_id: run.id)
        run.update!(status: "running", started_at: Time.current)
        acquired = true
      end
      begin
        raise Error, "Mirror module is disabled" unless setting.project.module_enabled?(:mirror)
        # A removed or unavailable adapter must not silently shrink a scheduled run.
        raise Error, "Unavailable modules: #{setting.unavailable_modules.join(', ')}" if setting.unavailable_modules.any?
        destination_url = ENV.fetch("MIRROR_DESTINATION_URL") { raise Error, "MIRROR_DESTINATION_URL is not configured for the worker" }
        config = setting.synchronization_config(destination_url: destination_url).merge("confirm_deletions" => run.confirm_deletions?)
        source_url = config.fetch("source_url").sub(%r{/+\z}, "")
        destination_url = destination_url.sub(%r{/+\z}, "")
        raise Error, "Cannot mirror a project onto itself" if source_url == destination_url && setting.source_project_id == setting.project_id
        key = Digest::SHA256.hexdigest(JSON.generate([source_url, setting.source_project_id, destination_url, setting.project_id]))
        run.update!(source_url: source_url, connection_key: key)
        destination_key = ENV.fetch("MIRROR_DESTINATION_API_KEY") { raise Error, "MIRROR_DESTINATION_API_KEY is not configured for the worker" }
        destination = Client.new(url: destination_url, api_key: destination_key, allow_http: config.fetch("allow_http"))
        runner = Runner.new(source: setting.source_client(purpose: run.apply? ? "synchronization" : "preview"), destination: destination, store: DatabaseStore.new(key, project_id: setting.project_id))
        # Also share the legacy operator task's local lock on this host.
        FileUtils.mkdir_p(Rails.root.join("tmp"))
        File.open(Rails.root.join("tmp", "mirror-#{key}.lock"), "a", 0600) do |lock|
          raise Error, "Synchronization already running" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          # Complete prevalidation before the first import write. An apply request
          # also records blocked secondary links so managers can diagnose the failure.
          # The preview reports every object error at once instead of the first one.
          checked = 0
          preview = runner.run(config.merge("on_error" => "collect"), track_relation_blocks: run.apply?) do
            # Without a total yet, processed_records counts the objects checked so far.
            checked += 1
            run.update_columns(processed_records: checked) if (checked % 25).zero?
          end
          totals = setting.selected_modules.to_h { |key| [key, 0] }
          preview.each { |event| totals[event.fetch(:module)] += 1 }
          run.update!(total_records: preview.size, processed_records: 0, module_totals: JSON.generate(totals))
          preview_errors = preview.count { |event| event[:action] == "error" }
          # "skip" writes everything else; "stop" writes nothing while an object fails.
          if run.apply? && (preview_errors.zero? || setting.on_error == "skip")
            runner.run(config.merge("on_error" => setting.on_error), apply: true) { |event| run.append_event(event) }
          else
            preview.each { |event| run.append_event(event) }
          end
        end
        errors = run.log_events.select { |event| event["action"] == "error" }
        # A value first used on the source after the last reference refresh is missing from
        # the mapping tabs: read the references again, so that they list it.
        catalog = setting.source_catalog
        stale = errors.any? do |event|
          code, params = Diagnosis.cause(event["reason"], event["details"])
          code == "missing_mapping" && !catalog.fetch(params["kind"], {}).key?(params["id"])
        end
        setting.request_catalog_refresh! if stale && !setting.reload.catalog_refreshing?
        if errors.empty?
          run.finish!(status: "succeeded")
        else
          # Partial ("skip"): the other objects were written, or would be for a preview,
          # so a few failing objects do not block the rest. Failed ("stop"): nothing is.
          partial = setting.on_error == "skip"
          run.finish!(status: partial ? "partial" : "failed",
            error_message: "#{errors.size} object(s) not synchronized; first: #{errors.first['reason']}")
        end
      rescue StandardError => error
        # Unexpected exception text can contain URLs, credentials or private records.
        message = error.is_a?(Error) ? error.message : "Internal synchronization error (#{error.class.name})"
        run.finish!(status: "failed", error_message: message)
      # Release only our own lease. A process crash cannot run this cleanup, so
      # recovery requires checking whether a write succeeded before another run.
      ensure
        setting.with_lock do
          if acquired && setting.running_run_id == run.id
            values = { running_run_id: nil }
            values[:next_sync_at] = Time.current + setting.sync_interval_minutes.minutes if setting.auto_sync_enabled?
            setting.update_columns(values)
          end
        end
      end
    end
  end
end
