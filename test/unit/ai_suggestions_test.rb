# frozen_string_literal: true
# File: redmine_mirror/test/unit/ai_suggestions_test.rb
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
# AI proposals (doc/AI.md): what is sent, as whom, within which budget, and when it stops.

require_relative "../test_helper"

class MirrorAiSuggestionsTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles, :enabled_modules, :trackers,
    :projects_trackers, :issue_statuses, :enumerations, :workflows

  # Answers like the API; records what it was sent and as whom.
  class FakeClient
    attr_reader :calls
    def initialize(answer = nil, error: nil)
      @answer, @error, @calls = answer, error, []
    end
    def host; "localhost"; end
    def chat(_instructions, content)
      @calls << [JSON.parse(content), User.current.login]
      raise @error if @error
      [@answer, 120]
    end
  end

  def setup
    @project = Project.find(1)
    @project.enable_module!(:mirror)
    @setting = MirrorProjectSetting.new(project: @project, source_url: "https://source.example/redmine", source_project_id: 12)
    @setting.selected_modules = %w[issue_tracking]
    @setting.api_key = "private-api-key"
    @catalog = { "status" => { "11" => "Nouveau", "12" => "assigned", "13" => "Résolu", "14" => "Unused", "15" => "Fermé" },
      "status_used" => %w[11 12 13 15], "tracker" => {}, "priority" => {}, "user" => { "7" => "Remote Alice" } }
    @setting.source_catalog = @catalog
    @setting.save!
    @project.mirror_reference_mappings.create!(reference_type: "status", source_id: 15, mode: "existing", destination_id: 5)
    @config = MirrorAiConfig.create!(enabled: true, provider: "ollama", model: "llama3.1", daily_request_limit: 5)
    @status = @setting.mapping_tables.find { |table| table.key == "status" }
  end

  def request!(kinds = ["status"])
    @setting.update_columns(ai_status: "pending", ai_tables: JSON.generate(kinds), ai_requested_by_id: 2)
  end

  def test_only_used_unmapped_references_without_namesakes_are_pending
    # "assigned" matches Assigned; "Unused" is not used; "Fermé" is mapped.
    assert_equal %w[11 13], RedmineMirror::Ai.pending_sources(@setting, @status).keys
  end

  def test_worker_asks_as_the_requester_counts_usage_and_merges_valid_answers
    client = FakeClient.new({ "matches" => [{ "source_id" => "11", "local_id" => "1", "confidence" => 0.9 },
      { "source_id" => "13", "local_id" => "999", "confidence" => 0.9 }] })
    MirrorAiConfig.any_instance.stubs(:client).returns(client)
    request!
    RedmineMirror::Ai.process_requests
    @setting.reload
    assert_equal "done", @setting.ai_status
    payload, login = client.calls.first
    assert_equal "jsmith", login
    assert_equal [{ "id" => "11", "name" => "Nouveau" }, { "id" => "13", "name" => "Résolu" }], payload["source"]
    ai = @setting.source_catalog["ai_suggestions"]
    assert_equal({ "11" => { "id" => "1", "confidence" => 0.9 } }, ai.dig("tables", "status"))
    assert_equal ["llama3.1", "localhost"], ai.values_at("model", "host")
    assert_equal [1, 120], [MirrorAiUsage.today.requests, MirrorAiUsage.today.tokens]
    # References sent are not sent again, with or without an answer.
    assert_empty RedmineMirror::Ai.pending_sources(@setting, @status)
  end

  def test_provider_refusal_blocks_the_configuration
    MirrorAiConfig.any_instance.stubs(:client).returns(FakeClient.new(error: RedmineMirror::Ai::Blocked.new("quota exhausted")))
    request!
    RedmineMirror::Ai.process_requests
    assert_equal ["failed", "quota exhausted"], @setting.reload.values_at(:ai_status, :ai_error)
    @config.reload
    assert_equal "quota exhausted", @config.blocked_reason
    refute @config.usable?
  end

  def test_daily_limit_stops_before_any_request
    MirrorAiUsage.today.update!(requests: 5)
    client = FakeClient.new({})
    MirrorAiConfig.any_instance.stubs(:client).returns(client)
    request!
    RedmineMirror::Ai.process_requests
    assert_equal "failed", @setting.reload.ai_status
    assert_match(/daily limit/, @setting.ai_error)
    assert_empty client.calls
    assert_equal 0, @config.budget_left
  end

  # The limit reached on the second batch keeps the answers of the first one.
  def test_answered_batches_are_kept_when_the_limit_stops_the_next
    statuses = (1..60).to_h { |index| [(300 + index).to_s, "Source status #{index}"] }
    @setting.update!(source_catalog: { "status" => statuses })
    @config.update!(daily_request_limit: 1)
    MirrorAiConfig.any_instance.stubs(:client).returns(FakeClient.new({ "matches" => [{ "source_id" => "301", "local_id" => "1", "confidence" => 0.8 }] }))
    request!
    RedmineMirror::Ai.process_requests
    @setting.reload
    assert_match(/daily limit/, @setting.ai_error)
    ai = @setting.source_catalog["ai_suggestions"]
    assert_equal({ "301" => { "id" => "1", "confidence" => 0.8 } }, ai.dig("tables", "status"))
    assert_equal 50, ai.dig("asked", "status").size
    assert_equal 10, RedmineMirror::Ai.pending_sources(@setting, @status).size
  end

  def test_user_names_need_the_option
    refute_includes RedmineMirror::Ai.tables(@config), "user"
    client = FakeClient.new({})
    MirrorAiConfig.any_instance.stubs(:client).returns(client)
    request!(["user"])
    RedmineMirror::Ai.process_requests
    assert_empty client.calls
    @config.update!(send_user_names: true)
    assert_includes RedmineMirror::Ai.tables(@config), "user"
  end

  def test_key_is_encrypted_and_gemini_lists_light_chat_models_first
    config = MirrorAiConfig.new(provider: "gemini", model: "gemini-flash-lite", enabled: true)
    refute config.tap(&:save!).usable?
    config.update!(api_key: "gemini-secret")
    refute_includes config.encrypted_api_key, "gemini-secret"
    assert_equal "gemini-secret", config.reload.api_key
    assert config.usable?
    config.update!(models_cache: JSON.generate(%w[gemini-pro text-embedding-004 gemini-flash-lite imagen-3]))
    assert_equal %w[gemini-flash-lite gemini-pro], config.models
    # "gemini" is not read as "mini".
    refute MirrorAiConfig.light?("gemini-2.5-flash")
    assert MirrorAiConfig.light?("llama3.1:8b")
    refute MirrorAiConfig.new(provider: "other", url: "http://ai.example.com/v1", enabled: true).valid?
  end
end
