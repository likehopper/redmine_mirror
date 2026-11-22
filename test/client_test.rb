# frozen_string_literal: true
# File: redmine_mirror/test/client_test.rb
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

require "minitest/autorun"
require "socket"
require_relative "../lib/redmine_mirror"

class MirrorClientTest < Minitest::Test
  def serve(responses, application_key: nil)
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new do
      responses.each do |status, body|
        socket = server.accept
        lines = []
        while (line = socket.gets) && line != "\r\n"
          lines << line
        end
        requests << lines.join
        socket.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        socket.close
      end
    end
    client = RedmineMirror::Client.new(url: "http://127.0.0.1:#{server.addr[1]}/redmine", api_key: "test-token",
      application_key: application_key, allow_http: true)
    yield client, requests
    thread.value
  ensure
    server&.close
    thread&.kill
  end

  def with_issue_cache(count:, bytes:)
    names = %w[MIRROR_ISSUE_CACHE MIRROR_ISSUE_CACHE_BYTES]
    previous = names.map { |name| ENV[name] }
    ENV[names[0]] = count.to_s
    ENV[names[1]] = bytes.to_s
    yield
  ensure
    names.zip(previous).each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
  end

  def test_issue_cache_evicts_least_recently_used_detail
    with_issue_cache(count: 2, bytes: 1024) do
      responses = [1, 2, 3, 2].map { |id| ["200 OK", JSON.generate("issue" => { "id" => id })] }
      serve(responses) do |client, requests|
        [1, 2, 1, 3, 1, 2].each { |id| assert_equal id, client.issue_detail(id)["id"] }
        assert_equal 4, requests.size
      end
    end
  end

  def test_issue_cache_byte_budget_and_caller_mutation
    detail = { "id" => 1, "description" => "é" * 20 }
    with_issue_cache(count: 10, bytes: JSON.generate(detail).bytesize) do
      responses = [detail, detail.merge("id" => 2), detail].map { |issue| ["200 OK", JSON.generate("issue" => issue)] }
      serve(responses) do |client, requests|
        client.issue_detail(1)["description"].clear
        assert_equal detail, client.issue_detail(1)
        client.issue_detail(2)
        assert_equal detail, client.issue_detail(1)
        assert_equal 3, requests.size
      end
    end
  end

  def test_disabled_and_oversized_issue_details_are_not_retained
    [[0, 1024], [-1, 1024], [10, 0], [10, -1], [10, 1]].each do |count, bytes|
      with_issue_cache(count: count, bytes: bytes) do
        responses = 2.times.map { ["200 OK", JSON.generate("issue" => { "id" => 1 })] }
        serve(responses) do |client, requests|
          2.times { assert_equal 1, client.issue_detail(1)["id"] }
          assert_equal 2, requests.size
        end
      end
    end
  end

  def test_pagination_and_subdirectory_and_authentication
    responses = [
      ["200 OK", JSON.generate("issues" => [{ "id" => 1 }], "total_count" => 2)],
      ["200 OK", JSON.generate("issues" => [{ "id" => 2 }], "total_count" => 2)]
    ]
    serve(responses) do |client, requests|
      assert_equal [1, 2], client.each_record("issues", "project_id" => 3).map { |record| record["id"] }
      assert_includes requests.first, "/redmine/issues.json?"
      assert_includes requests.first.downcase, "x-redmine-api-key: test-token"
      assert_includes requests.last, "offset=1"
    end
  end

  def test_http_errors_hide_private_response_and_do_not_follow_redirects
    serve([["302 Found", "private secret"]]) do |client, _requests|
      error = assert_raises(RedmineMirror::Error) { client.get("issues.json") }
      assert_equal "Redmine API returned HTTP 302 for GET issues.json", error.message
      refute_includes error.message, "secret"
    end
  end

  # A Mirror source logs one session per client and names the lock it refuses on; any
  # other header value is ignored.
  def test_mirror_source_session_and_refusal
    responses = [["200 OK", "{}"], ["403 Forbidden\r\nX-Mirror-Source-Refusal: not_shared", ""], ["403 Forbidden\r\nX-Mirror-Source-Refusal: <script>", ""],
      ["403 Forbidden\r\nX-Mirror-Source-Refusal: address", ""]]
    serve(responses) do |client, requests|
      client.get("projects/1.json")
      assert_match(/x-mirror-session: #{client.session}\r\n/i, requests.first)
      assert_match(/\A[0-9a-f]{32}\z/, client.session)
      assert_equal "Redmine API returned HTTP 403 for GET issues.json (Mirror source: not_shared)", assert_raises(RedmineMirror::Error) { client.get("issues.json") }.message
      assert_equal "Redmine API returned HTTP 403 for GET issues.json", assert_raises(RedmineMirror::Error) { client.get("issues.json") }.message
      # A refused caller is said as such, not as a missing permission.
      assert_match(/refuses this Redmine's address/, assert_raises(RedmineMirror::Error) { client.get("issues.json") }.message)
    end
  end

  def test_application_key_is_sent_only_when_configured
    serve([["200 OK", "{}"]], application_key: "mirror-secret") do |client, requests|
      client.get("projects/1.json")
      assert_match(/x-mirror-application-key: mirror-secret\r\n/i, requests.first)
    end
  end

  def test_long_known_refusal_reason_is_kept_for_secure_fallbacks
    serve([["403 Forbidden\r\nX-Mirror-Source-Refusal: incremental_visibility", ""]]) do |client, _requests|
      error = assert_raises(RedmineMirror::Error) { client.get("projects/1/mirror/source/changes.json") }
      assert_includes error.message, "Mirror source: incremental_visibility"
    end
  end

  # A refused write gives Redmine's validation messages; other bodies stay hidden.
  def test_refused_write_reports_validation_messages
    responses = [["422 Unprocessable Entity", JSON.generate("errors" => ["User is invalid", "Date  is\nlocked"])],
      ["422 Unprocessable Entity", "not json"], ["500 Internal Server Error", JSON.generate("errors" => ["private trace"])]]
    serve(responses) do |client, _requests|
      assert_equal "Redmine API returned HTTP 422 for POST time_entries.json: User is invalid; Date is locked",
        assert_raises(RedmineMirror::Error) { client.create("time_entries.json", {}) }.message
      assert_equal "Redmine API returned HTTP 422 for POST time_entries.json", assert_raises(RedmineMirror::Error) { client.create("time_entries.json", {}) }.message
      refute_includes assert_raises(RedmineMirror::Error) { client.get("issues.json") }.message, "private"
    end
  end

  def test_empty_incomplete_page_fails_instead_of_looping
    serve([["200 OK", JSON.generate("issues" => [], "total_count" => 1)]]) do |client, _requests|
      assert_raises(RedmineMirror::Error) { client.each_record("issues", {}).to_a }
    end
  end

  def test_invalid_json_is_reported_without_body
    serve([["200 OK", "secret"]]) do |client, _requests|
      assert_equal "Invalid Redmine API response", assert_raises(RedmineMirror::Error) { client.get("issues.json") }.message
    end
  end

  def test_json_response_is_bounded_before_it_is_parsed
    serve([["200 OK", JSON.generate("issues" => [{ "subject" => "private" }])]]) do |client, _requests|
      error = assert_raises(RedmineMirror::Error) do
        client.send(:request, :get, "issues.json", max_bytes: 8)
      end
      assert_equal "Redmine API response exceeds the import limit of 0 KB", error.message
      refute_includes error.message, "private"
    end
  end
end
