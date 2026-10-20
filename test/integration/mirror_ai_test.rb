# frozen_string_literal: true
# File: redmine_mirror/test/integration/mirror_ai_test.rb
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
# AI proposals (doc/AI.md): the administration page, the per-table button and its limits,
# and the proposals in the mapping forms.

require_relative "../test_helper"

class MirrorAiTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :trackers,
    :projects_trackers, :issue_statuses, :enumerations, :workflows

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    Role.find(1).add_permission!(:manage_mirror)
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 12)
    @setting.selected_modules = %w[issue_tracking]
    @setting.api_key = "private-api-key"
    statuses = (1..12).to_h { |index| [(100 + index).to_s, "Source status #{index}"] }
    @setting.source_catalog = { "status" => statuses, "tracker" => { "1" => "Bug", "2" => "Evolution" }, "priority" => {} }
    @setting.catalog_status = "ready"
    @setting.save!
    @config = MirrorAiConfig.create!(enabled: true, provider: "gemini", model: "gemini-flash-lite", api_key: "gemini-secret")
  end

  def issues_tab
    get "/projects/ecookbook/settings/mirror", params: { mirror_tab: "issue_tracking" }
    assert_response :success
  end

  def test_admin_page_saves_an_encrypted_write_only_key_and_lists_models
    log_user("admin", "admin")
    get "/admin/mirror/ai"
    assert_response :success
    assert_select "#ai_api_key[value]", count: 0
    assert_no_match "gemini-secret", response.body
    patch "/admin/mirror/ai", params: { ai: { enabled: "1", provider: "gemini", model: "gemini-flash-lite", api_key: "",
      daily_request_limit: "20", min_references: "5", send_user_names: "0" } }
    @config.reload
    assert_equal ["gemini-secret", 20, 5], [@config.api_key, @config.daily_request_limit, @config.min_references]
    @config.block!("quota exhausted")
    RedmineMirror::Ai::Client.any_instance.stubs(:models).returns(%w[gemini-pro gemini-flash-lite text-embedding-004])
    post "/admin/mirror/ai/test"
    @config.reload
    assert_nil @config.blocked_at
    follow_redirect!
    assert_select "#ai_model option", text: /gemini-flash-lite — light, recommended/
    assert_select "#ai_model option", text: /embedding/, count: 0
    patch "/admin/mirror/ai", params: { ai: { clear_api_key: "1", enabled: "1", provider: "gemini", model: "gemini-flash-lite" } }
    refute @config.reload.api_key_set?
  end

  def test_admin_page_is_for_administrators_only
    log_user("jsmith", "jsmith")
    get "/admin/mirror/ai"
    assert_response :forbidden
  end

  # Offered from min_references unmapped references, queued as the requester, never saved.
  def test_button_follows_the_threshold_and_queues_a_request
    log_user("jsmith", "jsmith")
    issues_tab
    assert_select "#mirror-ai-offer-status a", text: "Propose with AI"
    assert_select "#mirror-ai-offer-status em", text: /12 references without correspondence: about 1 AI request/
    assert_select "#mirror-ai-offer-tracker", count: 0
    post "/projects/ecookbook/mirror/settings/modules/issue_tracking/ai/status"
    @setting.reload
    assert_equal ["pending", ["status"], 2], [@setting.ai_status, JSON.parse(@setting.ai_tables), @setting.ai_requested_by_id]
    assert_equal 0, @project.mirror_reference_mappings.count
    issues_tab
    assert_select "#mirror-ai-status[data-mirror-reload]"
    assert_select "#mirror-ai-offer-status", count: 0
    post "/projects/ecookbook/mirror/settings/modules/issue_tracking/ai/status"
    assert_equal "AI proposals are already being computed for this project.", flash[:error]
  end

  def test_button_is_refused_below_threshold_over_budget_or_when_blocked
    log_user("jsmith", "jsmith")
    @config.update!(min_references: 20)
    issues_tab
    assert_select ".mirror-ai-offer", count: 0
    post "/projects/ecookbook/mirror/settings/modules/issue_tracking/ai/status"
    assert_match(/from 20 references/, flash[:error])
    @config.update!(min_references: 10)
    MirrorAiUsage.today.update!(requests: @config.daily_request_limit)
    post "/projects/ecookbook/mirror/settings/modules/issue_tracking/ai/status"
    assert_match(/daily limit/, flash[:error])
    MirrorAiUsage.delete_all
    @config.block!("The AI provider refused the API key (HTTP 401)")
    issues_tab
    assert_select "#mirror-ai-blocked", text: /refused the API key/
    assert_select ".mirror-ai-offer", count: 0
    assert_nil @setting.reload.ai_status
  end

  # Proposals come after namesakes, only for valid choices, and disappear with AI disabled.
  def test_proposals_are_preselected_and_hidden_when_disabled
    catalog = @setting.source_catalog.merge("ai_suggestions" => { "model" => "gemini-flash-lite", "host" => "generativelanguage.googleapis.com",
      "at" => "2026-10-20T08:00:00Z", "tables" => { "tracker" => { "1" => { "id" => "3", "confidence" => 0.7 }, "2" => { "id" => "2", "confidence" => 0.81 } },
      "status" => { "101" => { "id" => "999", "confidence" => 0.9 } } } })
    @setting.update!(source_catalog: catalog)
    log_user("admin", "admin")
    issues_tab
    assert_select "#mirror-tracker-1 option[selected]", text: "Bug (#1)"
    assert_select "#mirror-tracker-2 option[selected]", text: "Feature request (#2)"
    assert_select "#mirror-table-tracker .mirror-ai-suggestion", count: 1, text: "proposed by AI (81%)"
    assert_select "#mirror-ai-suggestions", text: /1 correspondences proposed by AI.*gemini-flash-lite/
    assert_select "#mirror-status-101 option[selected]", count: 0
    @config.update!(enabled: false)
    issues_tab
    assert_select ".mirror-ai-suggestion", count: 0
    assert_select ".mirror-ai-offer", count: 0
  end
end
