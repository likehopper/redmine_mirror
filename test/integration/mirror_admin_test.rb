# frozen_string_literal: true
# File: redmine_mirror/test/integration/mirror_admin_test.rb
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

class MirrorAdminTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :trackers, :projects_trackers

  def setup
    @first = configure(Project.find(1), modules: %w[issue_tracking wiki], source_wins: true)
    @second = configure(Project.find(2), modules: %w[issue_tracking], source_wins: false)
    now = Time.current
    [[1, 120, "succeeded"], [1, 60, "partial"], [2, 30, "failed"]].each do |project_id, seconds, status|
      MirrorSyncRun.create!(project_id: project_id, trigger: "manual", apply: true, status: status, started_at: now - seconds - 60,
        finished_at: now - 60, duration_seconds: seconds, processed_records: 10)
    end
    MirrorSyncRun.create!(project_id: 2, trigger: "manual", apply: true, status: "running", started_at: now)
    MirrorConflict.create!(project_id: 1, connection_key: "k" * 64, module_key: "issue_tracking", source_id: 7, message: "Local modification detected", status: "open")
  end

  def configure(project, modules:, source_wins:)
    project.enable_module!(:mirror)
    setting = MirrorProjectSetting.new(project: project, source_url: "https://source.example/redmine", source_project_id: project.id + 10, source_wins: source_wins)
    setting.selected_modules = modules
    setting.api_key = "private-api-key"
    setting.save!
    setting
  end

  def test_only_administrators_see_the_overview
    log_user("jsmith", "jsmith")
    get "/admin/mirror"
    assert_response 403
  end

  def test_overview_lists_projects_with_activity_load_and_totals
    log_user("admin", "admin")
    get "/admin/mirror", params: { set_filter: 1, c: %w[project source_wins activity last_run_status runs_count duration_total open_conflicts],
      t: %w[runs_count duration_total open_conflicts] }
    assert_response :success
    assert_select "#admin-menu a.icon-mirror-admin.selected"
    assert_select "table.mirror-admin-projects tbody tr", count: 2
    assert_select "table.mirror-admin-projects td.project a[href='/projects/ecookbook/mirror']", text: "eCookbook"
    assert_select "table.mirror-admin-projects td.activity", text: "Running"
    assert_select "table.mirror-admin-projects td.duration_total", text: "3 min"
    # The running run counts too.
    assert_select "p.query-totals .total-for-runs-count span.value", text: "4"
    assert_select "p.query-totals .total-for-open-conflicts span.value", text: "1"
    assert_no_match "private-api-key", response.body
    # A computed date is shown as a date, whatever the database returns.
    get "/admin/mirror", params: { set_filter: 1, c: %w[project last_run_at] }
    cells = css_select("table.mirror-admin-projects td.last_run_at").map { |cell| cell.text.strip }
    assert_equal 2, cells.size
    # Formatted by Redmine: no seconds or microseconds, unlike the raw value.
    cells.each { |text| refute_match(/\d{2}:\d{2}:\d{2}/, text) }
  end

  def test_grouping_counts_and_totals_match_the_rows
    log_user("admin", "admin")
    get "/admin/mirror", params: { set_filter: 1, group_by: "source_wins", c: %w[project runs_count], t: %w[runs_count] }
    assert_response :success
    assert_select "tr.group", count: 2
    assert_select "tr.group", text: /Yes\s*1\s*Runs: 2/
    assert_select "tr.group", text: /No\s*1\s*Runs: 2/
  end

  def test_filters_on_activity_and_module_and_sort_on_a_computed_column
    log_user("admin", "admin")
    get "/admin/mirror", params: { set_filter: 1, f: %w[activity], op: { activity: "=" }, v: { activity: %w[running] }, c: %w[project] }
    assert_select "table.mirror-admin-projects tbody tr", count: 1
    assert_select "td.project", text: "OnlineStore"
    get "/admin/mirror", params: { set_filter: 1, f: %w[module], op: { module: "=" }, v: { module: %w[wiki] }, c: %w[project] }
    assert_select "td.project", text: "eCookbook"
    assert_select "table.mirror-admin-projects tbody tr", count: 1
    get "/admin/mirror", params: { set_filter: 1, sort: "runs_count:desc", c: %w[project runs_count] }
    assert_equal %w[eCookbook OnlineStore], css_select("td.project").map(&:text)
  end

  def test_csv_export
    log_user("admin", "admin")
    get "/admin/mirror.csv", params: { set_filter: 1, c: %w[project source_url runs_count] }
    assert_response :success
    assert_match %r{\Atext/csv}, response.media_type
    assert_includes response.body, "eCookbook"
    assert_includes response.body, "https://source.example/redmine"
  end
end
