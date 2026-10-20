# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/client.rb
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
# Read and write trusted Redmine REST endpoints without leaking credentials or private responses.

require "net/http"
require "securerandom"
require "uri"
module RedmineMirror
  class Error < StandardError; end
  class Client
    # Credentials belong to one trusted base URL. Reject userinfo, queries and
    # fragments so they cannot alter the authenticated request destination.
    # Sources running Mirror log their accesses by session: one per client (a run or a
    # reference refresh), with what it is for (Source::PURPOSES).
    attr_reader :session

    def initialize(url:, api_key:, allow_http: false, purpose: nil)
      @base_uri = URI(url.to_s.end_with?("/") ? url : "#{url}/")
      unless @base_uri.host && (@base_uri.scheme == "https" || (allow_http && @base_uri.scheme == "http")) &&
             !@base_uri.userinfo && !@base_uri.query && !@base_uri.fragment
        raise Error, "A trusted HTTPS Redmine URL is required"
      end
      raise Error, "Missing API key" if api_key.to_s.empty?
      @api_key = api_key
      @session = SecureRandom.hex(16)
      @purpose = purpose
    rescue URI::InvalidURIError
      raise Error, "A trusted HTTPS Redmine URL is required"
    end

    def get(path, params = {})
      request(:get, path, params: params)
    end

    # Every issue association modules read, fetched once per issue for a whole run or
    # catalog refresh. The cache is bounded to keep very large projects in memory limits.
    ISSUE_DETAIL_INCLUDES = "journals,attachments,relations,watchers,children"

    def issue_detail(id)
      @issue_details ||= {}
      id = Integer(id)
      return @issue_details[id] if @issue_details.key?(id)
      detail = get("issues/#{id}.json", "include" => ISSUE_DETAIL_INCLUDES).fetch("issue")
      @issue_details.shift if @issue_details.size >= Integer(ENV.fetch("MIRROR_ISSUE_CACHE", "5000"))
      @issue_details[id] = detail
    end

    def create(path, payload)
      request(:post, path, payload: payload)
    end

    def update(path, payload)
      request(:put, path, payload: payload)
    end

    # Construct a source-relative download path instead of trusting API-supplied
    # content URLs that could send the key to another host.
    # A Mirror source serves shared files through its own path (Adapters::Documents).
    def download_attachment(id, max_bytes: 32 * 1024 * 1024, path: nil)
      request(:get, path || "attachments/download/#{Integer(id)}", binary: true, max_bytes: max_bytes)
    end

    # Redmine paginates collections. Reject empty intermediate pages rather than
    # looping forever or silently reporting a complete import.
    def each_record(collection, params)
      return enum_for(__method__, collection, params) unless block_given?
      offset = 0
      loop do
        page = get("#{collection}.json", params.merge("offset" => offset, "limit" => 100))
        records = page.fetch(collection)
        raise Error, "Invalid API collection" unless records.is_a?(Array)
        records.each { |record| yield record }
        offset += records.length
        break if offset >= Integer(page.fetch("total_count"))
        raise Error, "Pagination made no progress" if records.empty?
      end
    end

    private

    def request(method, path, params: {}, payload: nil, binary: false, max_bytes: 32 * 1024 * 1024)
      raise Error, "Invalid API path" unless path.match?(/\A[A-Za-z0-9_\/.%~-]+\z/) && !path.include?("..") && !path.start_with?("/")
      uri = URI.join(@base_uri.to_s, path)
      uri.query = URI.encode_www_form(params) unless params.empty?
      request = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.fetch(method).new(uri)
      request["X-Redmine-API-Key"] = @api_key
      request["X-Mirror-Session"] = @session
      request["X-Mirror-Purpose"] = @purpose if @purpose
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload) if payload
      http_client = Net::HTTP.new(uri.host, uri.port, nil)
      http_client.use_ssl = uri.scheme == "https"
      http_client.open_timeout = 10
      http_client.read_timeout = 60
      # A retry after a transport failure could duplicate a successful POST.
      http_client.max_retries = 0
      # Stream attachments with a size bound before retaining the entire body.
      if binary
        attachment_bytes = +"".b
        http_client.start do |connection|
          connection.request(request) do |response|
            raise Error, "Redmine API returned HTTP #{response.code} for GET #{path}#{refusal(response)}" unless response.is_a?(Net::HTTPSuccess)
            response.read_body do |chunk|
              raise Error, "Attachment exceeds the import limit of #{max_bytes / 1024} KB" if attachment_bytes.bytesize + chunk.bytesize > max_bytes
              attachment_bytes << chunk
            end
          end
        end
        return attachment_bytes
      end
      response = http_client.start { |connection| connection.request(request) }
      # Never follow redirects or expose response bodies (which can contain private data).
      # The path names the refused resource, typically a missing source permission.
      raise Error, "Redmine API returned HTTP #{response.code} for #{method.to_s.upcase} #{path}#{refusal(response)}" unless response.is_a?(Net::HTTPSuccess)
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    rescue JSON::ParserError, KeyError, ArgumentError
      raise Error, "Invalid Redmine API response"
    rescue IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Error, "Redmine API connection failed; a write may have succeeded, inspect before retrying"
    end

    # The lock a Mirror source names when it refuses (Source.refusal): a known word only.
    def refusal(response)
      reason = response["X-Mirror-Source-Refusal"].to_s
      reason.match?(/\A[a-z_]{1,20}\z/) ? " (Mirror source: #{reason})" : ""
    end
  end
end
