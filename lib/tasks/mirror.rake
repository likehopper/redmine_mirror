# frozen_string_literal: true
# File: redmine_mirror/lib/tasks/mirror.rake
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
# Provide worker ticks and explicit preview/apply operator entry points.

require "fileutils"
namespace :redmine_mirror do
  desc "Enqueue due projects and process queued Mirror synchronizations"
  task tick: :environment do
    # After an upgrade, explain the missing step instead of failing on a missing column.
    unless MirrorProjectSetting.schema_current?
      abort "Redmine Mirror migrations are pending: run `bundle exec rake redmine:plugins:migrate RAILS_ENV=production`, then restart Redmine and the worker."
    end
    RedmineMirror::Synchronization.tick
  end

  desc "Preview project synchronization; APPLY=1 enables destination API writes"
  task sync: :environment do
    # Project mode uses the same lease, exclusions and persisted logs as the UI.
    # The standalone JSON path below keeps only its legacy host-local lock.
    if ENV["MIRROR_PROJECT_ID"].present?
      project = Project.find(ENV.fetch("MIRROR_PROJECT_ID"))
      raise RedmineMirror::Error, "Mirror module is disabled on this project" unless project.module_enabled?(:mirror)
      setting = project.mirror_project_setting
      raise RedmineMirror::Error, "Project has no Mirror configuration" unless setting
      run = RedmineMirror::Synchronization.enqueue(setting, apply: ENV["APPLY"] == "1", trigger: "operator")
      RedmineMirror::Synchronization.execute(run)
      run.reload
      puts JSON.pretty_generate(run.log_events)
      raise RedmineMirror::Error, run.error_message if run.status == "failed"
      next
    else
      config = JSON.parse(File.read(ENV.fetch("MIRROR_CONFIG")))
      source_api_key = ENV.fetch("MIRROR_SOURCE_API_KEY")
    end
    source_url = config.fetch("source_url").sub(%r{/+\z}, "")
    destination_url = config.fetch("destination_url").sub(%r{/+\z}, "")
    if source_url == destination_url && config.fetch("source_project_id").to_i == config.fetch("destination_project_id").to_i
      raise RedmineMirror::Error, "Cannot mirror a project onto itself"
    end
    identity = [source_url, config.fetch("source_project_id"), destination_url, config.fetch("destination_project_id")]
    key = Digest::SHA256.hexdigest(JSON.generate(identity))
    # Operator-only local task; source credentials are encrypted in project settings.
    lock_path = Rails.root.join("tmp", "mirror-#{key}.lock")
    FileUtils.mkdir_p(lock_path.dirname)
    File.open(lock_path, "a", 0600) do |lock|
      raise RedmineMirror::Error, "Synchronization already running" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      options = { allow_http: config.fetch("allow_http", false) == true }
      source = RedmineMirror::Client.new(url: source_url, api_key: source_api_key, **options)
      destination = RedmineMirror::Client.new(url: destination_url, api_key: ENV.fetch("MIRROR_DESTINATION_API_KEY"), **options)
      runner = RedmineMirror::Runner.new(source: source, destination: destination, store: RedmineMirror::DatabaseStore.new(key))
      # Validate all currently visible records before beginning destination writes.
      preview = runner.run(config)
      puts JSON.pretty_generate(ENV["APPLY"] == "1" ? runner.run(config, apply: true) : preview)
    end
  end
end
