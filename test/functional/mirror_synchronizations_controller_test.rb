# frozen_string_literal: true
# File: redmine_mirror/test/functional/mirror_synchronizations_controller_test.rb
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
# Verify Mirror behavior, project boundaries and repeatable synchronization.

require_relative "../test_helper"
require "minitest/mock"

class MirrorSynchronizationsControllerTest < ActionController::TestCase
  tests MirrorSynchronizationsController
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://remote.example", source_project_id: 12)
    @setting.selected_modules = ["issue_tracking"]
    @setting.api_key = "private-source-key"
    @setting.save!
    @request.session[:user_id] = 1
  end

  def test_manual_apply_is_queued_once
    post :create, params: { project_id: @project.identifier, mode: "apply" }
    run = @project.mirror_sync_runs.first!
    assert_redirected_to project_mirror_run_path(@project, run)
    assert run.apply?
    assert_equal "queued", run.status
    assert_equal 1, run.requested_by_id
    post :create, params: { project_id: @project.identifier, mode: "apply" }
    assert_equal 1, @project.mirror_sync_runs.count
    assert flash[:error].present?
  end

  def test_queued_run_can_be_cancelled_but_not_a_running_one
    run = RedmineMirror::Synchronization.enqueue(@setting, apply: true, trigger: "manual")
    patch :cancel, params: { project_id: @project.identifier, id: run.id }
    assert_redirected_to project_mirror_settings_path(@project, tab: "synchronization")
    assert_equal "cancelled", run.reload.status
    assert run.finished_at
    # The project is no longer blocked, and a cancelled run is never executed.
    RedmineMirror::Synchronization.execute(run)
    assert_equal "cancelled", run.reload.status
    running = RedmineMirror::Synchronization.enqueue(@setting, apply: false, trigger: "manual")
    running.update!(status: "running")
    patch :cancel, params: { project_id: @project.identifier, id: running.id }
    assert flash[:error].present?
    assert_equal "running", running.reload.status
  end

  def test_run_log_summarizes_actions_and_filters_special_cases
    run = @project.mirror_sync_runs.create!(apply: true, trigger: "manual", status: "succeeded", events: JSON.generate([
      { "module" => "issue_tracking", "source_id" => 3, "destination_id" => 1, "action" => "create", "flags" => ["converted:textile>html", "issue_references"] },
      { "module" => "issue_tracking", "source_id" => 4, "destination_id" => 2, "action" => "create" },
      { "module" => "time_tracking", "source_id" => 9, "destination_id" => 5, "action" => "unchanged" }]))
    get :show, params: { project_id: @project.identifier, id: run.id }
    assert_select "#mirror-run-summary", text: /Converted: Textile → HTML \(CKEditor\) \(1\)/
    assert_select "#mirror-log tbody tr", 3
    get :show, params: { project_id: @project.identifier, id: run.id, flag: "any" }
    assert_select "#mirror-log tbody tr", 1
    assert_select "#mirror-log .mirror-flag", text: "Issue numbers (#123)"
  end

  def test_warnings_and_conflicts_link_to_where_they_are_fixed
    field = IssueCustomField.create!(name: "Impact level", field_format: "string", trackers: [Tracker.first])
    run = @project.mirror_sync_runs.create!(apply: true, trigger: "manual", status: "succeeded", events: JSON.generate([
      { "module" => "issue_tracking", "source_id" => 3, "action" => "create",
        "warnings" => ["Custom field \"Impact level\" is not enabled for destination tracker \"Bug\": enable it, or ignore source field #7; the value was not imported"] },
      { "module" => "issue_watchers", "source_id" => 4, "action" => "error", "reason" => "Local modification detected for issue_watchers" }]))
    get :show, params: { project_id: @project.identifier, id: run.id }
    assert_select "#mirror-warning-causes a.mirror-fix[href=?]", "/custom_fields/#{field.id}/edit", text: "enable the field for this tracker"
    assert_select "#mirror-error-causes a.mirror-fix[href*='tab=conflicts']", text: "resolve the conflict"
  end

  def test_unauthorized_member_cannot_cancel
    run = RedmineMirror::Synchronization.enqueue(@setting, apply: true, trigger: "manual")
    @request.session[:user_id] = 2
    patch :cancel, params: { project_id: @project.identifier, id: run.id }
    assert_response :forbidden
    assert_equal "queued", run.reload.status
  end

  def test_preview_and_schedule
    post :create, params: { project_id: @project.identifier, mode: "preview" }
    assert_not @project.mirror_sync_runs.first!.apply?
    patch :update, params: { project_id: @project.identifier, schedule: { enabled: "1", interval_minutes: "15" } }
    assert @setting.reload.auto_sync_enabled?
    assert_equal 15, @setting.sync_interval_minutes
    assert @setting.next_sync_at > Time.current
    patch :update, params: { project_id: @project.identifier, schedule: { enabled: "0", interval_minutes: "60" } }
    assert_not @setting.reload.auto_sync_enabled?
    assert_nil @setting.next_sync_at
  end

  def test_invalid_frequency_is_rejected
    patch :update, params: { project_id: @project.identifier, schedule: { enabled: "1", interval_minutes: "0" } }
    assert_not @setting.reload.auto_sync_enabled?
    assert flash[:error].present?
  end

  def test_unauthorized_member_cannot_enqueue_or_schedule
    @request.session[:user_id] = 2
    post :create, params: { project_id: @project.identifier, mode: "apply" }
    assert_response :forbidden
    patch :update, params: { project_id: @project.identifier, schedule: { enabled: "1", interval_minutes: "15" } }
    assert_response :forbidden
    assert_equal 0, MirrorSyncRun.count
  end

  def test_run_log_is_project_scoped_and_escaped
    run = @project.mirror_sync_runs.create!(trigger: "manual", status: "failed", error_message: "<script>private</script>")
    get :show, params: { project_id: @project.identifier, id: run.id }
    assert_response :success
    assert_select ".flash.error", text: "<script>private</script>"
    assert_no_match "<script>private</script>", response.body
    other = Project.create!(name: "Other", identifier: "other-sync", enabled_module_names: ["mirror"])
    MirrorProjectSetting.create!(project: other, source_url: "https://remote.example", source_project_id: 12,
      selected_modules: ["issue_tracking"], encrypted_api_key: @setting[:encrypted_api_key])
    get :show, params: { project_id: other.identifier, id: run.id }
    assert_response :not_found
  end

  def test_scheduler_enqueues_only_due_enabled_projects
    @setting.update!(auto_sync_enabled: true, sync_interval_minutes: 15, next_sync_at: 1.minute.ago)
    RedmineMirror::Synchronization.stub(:execute, nil) { RedmineMirror::Synchronization.tick }
    assert_equal 1, @project.mirror_sync_runs.count
    assert_equal "automatic", @project.mirror_sync_runs.first.trigger
    assert @setting.reload.next_sync_at > Time.current
    RedmineMirror::Synchronization.stub(:execute, nil) { RedmineMirror::Synchronization.tick }
    assert_equal 1, @project.mirror_sync_runs.count
  end

  # Runner double: one object fails in the preview; the apply run reports it again.
  class PartialRunner
    attr_reader :calls
    def initialize; @calls = []; end
    def run(config, apply: false, track_relation_blocks: false)
      @calls << [apply, config["on_error"]]
      events = [{ module: "issue_tracking", source_id: 1, action: "create" },
                { module: "issue_tracking", source_id: 2, action: "error", reason: "Missing user mapping for source ID 7" }]
      events.each { |event| yield event } if block_given?
      events
    end
  end

  def execute_with(runner, on_error:)
    @setting.update!(on_error: on_error)
    run = RedmineMirror::Synchronization.enqueue(@setting, apply: true, trigger: "manual")
    with_destination_env do
      RedmineMirror::Runner.stub(:new, runner) { RedmineMirror::Synchronization.execute(run) }
    end
    run.reload
  end

  def with_destination_env
    previous = ENV.values_at("MIRROR_DESTINATION_URL", "MIRROR_DESTINATION_API_KEY")
    ENV["MIRROR_DESTINATION_URL"], ENV["MIRROR_DESTINATION_API_KEY"] = "https://destination.example", "destination-key"
    yield
  ensure
    ENV["MIRROR_DESTINATION_URL"], ENV["MIRROR_DESTINATION_API_KEY"] = previous
  end

  def test_skip_mode_writes_the_rest_and_reports_partial_success
    runner = PartialRunner.new
    run = execute_with(runner, on_error: "skip")
    assert_equal [[false, "collect"], [true, "skip"]], runner.calls
    assert_equal "partial", run.status
    assert_includes run.error_message, "Missing user mapping for source ID 7"
    assert_equal 100, run.progress_percentage
  end

  def test_stop_mode_writes_nothing_and_lists_every_error
    runner = PartialRunner.new
    run = execute_with(runner, on_error: "stop")
    assert_equal [[false, "collect"]], runner.calls
    assert_equal "failed", run.status
    assert_equal %w[create error], run.log_events.map { |event| event["action"] }
  end

  def test_run_log_groups_errors_by_cause
    run = @project.mirror_sync_runs.create!(apply: true, trigger: "manual", status: "partial", events: JSON.generate(
      [1, 2, 3].map { |id| { "module" => "time_tracking", "source_id" => id, "action" => "error", "reason" => "Missing user mapping for source ID 7" } }))
    get :show, params: { project_id: @project.identifier, id: run.id }
    assert_select "#mirror-error-causes li", text: /Missing user mapping for source ID 7 — fix the mapping — 3 object\(s\)/
    assert_select "#mirror-error-causes a[href*='tab=users']", text: "fix the mapping"
    # A cause link lists only its own objects.
    events = JSON.parse(run.events) + [{ "module" => "issue_tracking", "source_id" => 9, "action" => "error", "reason" => "Other cause" }]
    run.update!(events: JSON.generate(events))
    get :show, params: { project_id: @project.identifier, id: run.id, action_filter: "error", reason: "Other cause" }
    assert_select "#mirror-log tbody tr", 1
    assert_select "#mirror-reason-filter", text: /Other cause/
  end

  def test_failure_is_logged_and_lock_is_released
    run = RedmineMirror::Synchronization.enqueue(@setting, apply: false, trigger: "manual")
    @setting.define_singleton_method(:source_client) { raise "private-source-key" }
    run.project.stub(:mirror_project_setting, @setting) { RedmineMirror::Synchronization.execute(run) }
    assert_equal "failed", run.reload.status
    assert_not_nil run.finished_at
    assert_no_match "private-source-key", run.error_message
    assert_nil @setting.reload.running_run_id
  end
  def test_disabled_automatic_execution_is_cancelled_without_acquiring_lock
    run = @project.mirror_sync_runs.create!(trigger: "automatic", apply: true)
    RedmineMirror::Synchronization.execute(run)
    assert_equal "cancelled", run.reload.status
    assert_nil @setting.reload.running_run_id
  end

  def test_log_filters_module_action_and_source_id
    run = @project.mirror_sync_runs.create!(trigger: "manual", events: JSON.generate([
      { module: "issue_tracking", source_id: 1, action: "create" },
      { module: "time_tracking", source_id: 2, action: "update" },
      { module: "time_tracking", source_id: 3, action: "unchanged" }]))
    get :show, params: { project_id: @project.identifier, id: run.id, module_key: "time_tracking", action_filter: "update", source_id: "2" }
    assert_response :success
    assert_select "#mirror-log tbody tr", count: 1
    assert_select "#mirror-log td", text: "Time tracking"
    assert_select "#mirror-log td", text: "2"
  end

  def test_progress_counts_completed_records_without_claiming_success
    run = @project.mirror_sync_runs.create!(trigger: "manual", status: "running", total_records: 2)
    assert_equal 0, run.progress_percentage
    run.append_event(module: "issue_tracking", source_id: 1, action: "create")
    assert_equal 50, run.reload.progress_percentage
    run.append_event(module: "time_tracking", source_id: 2, action: "create")
    assert_equal 99, run.progress_percentage
    run.update!(status: "succeeded")
    assert_equal 100, run.progress_percentage
  end

  def test_log_retains_local_id_and_remote_link
    run = @project.mirror_sync_runs.create!(trigger: "manual", source_url: "https://remote.example/redmine",
      events: JSON.generate([{ module: "issue_tracking", source_id: 12, destination_id: 34, action: "create" }]))
    get :show, params: { project_id: @project.identifier, id: run.id }
    assert_response :success
    assert_select 'a[href="https://remote.example/redmine/issues/12"]', text: "12"
    assert_select 'a[href="/issues/34"]', text: "34"
  end

end

class MirrorQueuedRunDisplayTest < ActionController::TestCase
  tests MirrorSettingsController
  fixtures :projects, :users, :roles, :members, :member_roles, :enabled_modules

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://remote.example", source_project_id: 12)
    @setting.selected_modules = ["issue_tracking"]
    @setting.api_key = "private-source-key"
    @setting.save!
    @request.session[:user_id] = 1
  end

  # A queued run shows its own (empty) dates, a cancel button, and a worker warning once stale.
  def test_queued_run_shows_its_own_dates_and_a_worker_warning_when_stale
    @project.mirror_sync_runs.create!(apply: false, trigger: "manual", status: "failed",
      started_at: 2.days.ago, finished_at: 2.days.ago)
    queued = RedmineMirror::Synchronization.enqueue(@setting, apply: true, trigger: "manual")
    get :show, params: { project_id: @project.identifier, tab: "synchronization" }
    assert_select "#mirror-queued-run form[action=?]", "/projects/#{@project.identifier}/mirror/synchronizations/#{queued.id}/cancel"
    assert_select "#mirror-queued-run .warning", count: 0
    assert_select "#mirror-sync-summary", text: /Started\s*—/
    queued.update_columns(created_at: 10.minutes.ago)
    get :show, params: { project_id: @project.identifier, tab: "synchronization" }
    assert_select "#mirror-queued-run .warning", text: /redmine_mirror:tick/
  end
end
