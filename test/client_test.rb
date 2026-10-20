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
  def serve(responses)
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
    client = RedmineMirror::Client.new(url: "http://127.0.0.1:#{server.addr[1]}/redmine", api_key: "test-token", allow_http: true)
    yield client, requests
    thread.value
  ensure
    server&.close
    thread&.kill
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
    responses = [["200 OK", "{}"], ["403 Forbidden\r\nX-Mirror-Source-Refusal: not_shared", ""], ["403 Forbidden\r\nX-Mirror-Source-Refusal: <script>", ""]]
    serve(responses) do |client, requests|
      client.get("projects/1.json")
      assert_match(/x-mirror-session: #{client.session}\r\n/i, requests.first)
      assert_match(/\A[0-9a-f]{32}\z/, client.session)
      assert_equal "Redmine API returned HTTP 403 for GET issues.json (Mirror source: not_shared)", assert_raises(RedmineMirror::Error) { client.get("issues.json") }.message
      assert_equal "Redmine API returned HTTP 403 for GET issues.json", assert_raises(RedmineMirror::Error) { client.get("issues.json") }.message
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
end
