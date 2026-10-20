# frozen_string_literal: true
# File: redmine_mirror/test/ai_test.rb
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
# Verify the normalized name proposals and the AI client rules of doc/AI.md.

require "minitest/autorun"
require "socket"
require_relative "../lib/redmine_mirror"

class MirrorAiTest < Minitest::Test
  # One HTTP exchange per response; yields the base URL and the raw requests received.
  def serve(responses)
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new do
      responses.each do |status, body|
        socket = server.accept
        head = +""
        while (line = socket.gets) && line != "\r\n"
          head << line
        end
        length = head[/content-length: (\d+)/i, 1].to_i
        requests << "#{head}\r\n#{socket.read(length)}"
        socket.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        socket.close
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}/v1", requests
    thread.value
  ensure
    server&.close
    thread&.kill
  end

  def completion(content, tokens: nil)
    body = { "choices" => [{ "message" => { "role" => "assistant", "content" => content } }] }
    body["usage"] = { "total_tokens" => tokens } if tokens
    JSON.generate(body)
  end

  def test_names_match_ignoring_case_accents_punctuation_and_word_order
    candidates = [["Jérôme Dupont", "4"], ["In progress", "2"], ["Bug", "1"], ["bug", "9"]]
    assert_equal "4", RedmineMirror::NameMatch.suggest("DUPONT, Jerome", candidates)
    assert_equal "2", RedmineMirror::NameMatch.suggest("in-progress", candidates)
    # Two local namesakes: no proposal.
    assert_nil RedmineMirror::NameMatch.suggest("Bug", candidates)
    assert_nil RedmineMirror::NameMatch.suggest(" ", candidates)
    assert_operator RedmineMirror::NameMatch.score("J. Dupont", "Jean Dupont"), :>, RedmineMirror::NameMatch.score("J. Dupont", "Marie Martin")
    assert_equal 1.0, RedmineMirror::NameMatch.score("Dupont, Jean", "jean DUPONT")
  end

  def test_client_requires_https_except_for_local_or_private_hosts
    %w[http://localhost:11434/v1 http://127.0.0.1:8080/v1 http://192.168.1.20/v1 http://ollama:11434/v1
       https://generativelanguage.googleapis.com/v1beta/openai].each do |url|
      RedmineMirror::Ai::Client.new(url: url, model: "m")
    end
    ["http://api.example.com/v1", "https://user:pass@api.example.com/v1", "https://api.example.com/v1?x=1", "ftp://localhost/"].each do |url|
      assert_raises(RedmineMirror::Error) { RedmineMirror::Ai::Client.new(url: url, model: "m") }
    end
    # A model is needed to chat, not to list the models.
    error = assert_raises(RedmineMirror::Error) { RedmineMirror::Ai::Client.new(url: "http://localhost/v1", model: " ").chat("x", "y") }
    assert_equal "Missing AI model", error.message
  end

  def test_suggester_sends_names_only_and_keeps_valid_answers
    answer = { "matches" => [
      { "source_id" => "12", "local_id" => "3", "confidence" => 0.92 },
      { "source_id" => "13", "local_id" => "99", "confidence" => 0.9 },  # unknown local ID
      { "source_id" => "77", "local_id" => "3", "confidence" => 0.9 },   # not sent
      { "source_id" => "14", "local_id" => "4", "confidence" => 0.2 }    # too uncertain
    ] }
    serve([["200 OK", completion("```json\n#{JSON.generate(answer)}\n```", tokens: 321)]]) do |url, requests|
      client = RedmineMirror::Ai::Client.new(url: url, model: "llama3.1", api_key: "ai-secret")
      calls = []
      suggester = RedmineMirror::Ai::Suggester.new(client, before_request: -> { calls << :before }, after_request: ->(tokens) { calls << tokens })
      found = suggester.suggest("status", [["12", "Nouveau"], ["13", "Fermé"], ["14", "Rejeté"]],
        [["3", "New"], ["4", "Closed"]])
      assert_equal({ "12" => { "id" => "3", "confidence" => 0.92 } }, found)
      assert_equal [:before, 321], calls
      request = requests.first
      assert_includes request, "POST /v1/chat/completions"
      assert_includes request.downcase, "authorization: bearer ai-secret"
      body = JSON.parse(request.split("\r\n\r\n", 2).last)
      assert_equal "llama3.1", body["model"]
      payload = JSON.parse(body["messages"].last["content"])
      assert_equal({ "reference_type" => "status", "source" => [{ "id" => "12", "name" => "Nouveau" }, { "id" => "13", "name" => "Fermé" },
        { "id" => "14", "name" => "Rejeté" }], "destination" => [{ "id" => "3", "name" => "New" }, { "id" => "4", "name" => "Closed" }] }, payload)
    end
  end

  def test_errors_hide_the_response_and_a_keyless_local_model_sends_no_authorization
    serve([["500 Internal Server Error", "private echo"], ["200 OK", completion("not json")]]) do |url, requests|
      client = RedmineMirror::Ai::Client.new(url: url, model: "m")
      error = assert_raises(RedmineMirror::Error) { client.chat("x", "y") }
      assert_equal "AI API returned HTTP 500", error.message
      error = assert_raises(RedmineMirror::Error) { client.chat("x", "y") }
      assert_equal "Invalid AI API response", error.message
      refute_includes requests.first.downcase, "authorization:"
    end
  end

  # Long local lists: each source comes with its closest candidates only.
  def test_long_lists_send_a_shortlist_of_candidates
    locals = (1..200).map { |id| [id.to_s, "Person #{id} Filler"] } + [["999", "Jerome Dupont"]]
    shortlist = RedmineMirror::Ai::Suggester.new(nil).shortlist([["7", "Jérôme DUPONT"]], locals)
    assert_equal RedmineMirror::Ai::SHORTLIST_SIZE, shortlist.size
    assert_equal ["999", "Jerome Dupont"], shortlist.first
    assert_equal locals.first(3), RedmineMirror::Ai::Suggester.new(nil).shortlist([["7", "x"]], locals.first(3))
  end

  # A refused budget stops before any request.
  def test_budget_refusal_sends_nothing
    client = Object.new
    def client.chat(*) = raise("no request expected")
    suggester = RedmineMirror::Ai::Suggester.new(client, before_request: -> { raise RedmineMirror::Ai::BudgetExhausted, "limit" })
    assert_raises(RedmineMirror::Ai::BudgetExhausted) { suggester.suggest("status", [["1", "A"]], [["2", "B"]]) }
  end

  # Quota, credit or key refusals block further requests; listing models checks the key.
  def test_provider_refusals_block_and_models_are_listed
    models = JSON.generate("object" => "list", "data" => [{ "id" => "models/gemini-flash-lite" }, { "id" => "gemini-pro" }])
    serve([["200 OK", models], ["429 Too Many Requests", "{\"error\":{\"status\":\"RESOURCE_EXHAUSTED\"}}"],
           ["401 Unauthorized", "secret echo"]]) do |url, requests|
      client = RedmineMirror::Ai::Client.new(url: url, model: "m", api_key: "k")
      assert_equal %w[gemini-flash-lite gemini-pro], client.models
      assert_includes requests.first, "GET /v1/models"
      error = assert_raises(RedmineMirror::Ai::Blocked) { client.chat("x", "y") }
      assert_match(/quota or credit exhausted \(HTTP 429\)/, error.message)
      error = assert_raises(RedmineMirror::Ai::Blocked) { client.chat("x", "y") }
      assert_equal "The AI provider refused the API key (HTTP 401)", error.message
    end
  end
end
