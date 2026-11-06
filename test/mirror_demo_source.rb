# frozen_string_literal: true
# File: redmine_mirror/test/mirror_demo_source.rb
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
# Replay the demo source project of test/fixtures/mirror_demo from its API answers.

require "json"
require "uri"

# The demo project of test/fixtures/mirror_demo (see generate.rb there): the answers a
# Redmine 4 source with Scrum, Redmine Tags and Mirror source gives the reader account.
# Answers the requests Mirror makes like that source, errors included (403 on categories
# and custom fields, users not shared); any other request answers 404.
class MirrorDemoSource
  DIRECTORY = File.expand_path("fixtures/mirror_demo", __dir__)
  FULL_DETAIL = RedmineMirror::Client::ISSUE_DETAIL_INCLUDES

  attr_reader :requests, :unrecorded, :downloads

  def self.answers
    @answers ||= JSON.parse(File.read(File.join(DIRECTORY, "answers.json"))).freeze
  end

  def self.files
    @files ||= JSON.parse(File.read(File.join(DIRECTORY, "downloads.json"))).freeze
  end

  def self.meta
    @meta ||= JSON.parse(File.read(File.join(DIRECTORY, "meta.json"))).freeze
  end

  def self.key(path, params = {})
    params.empty? ? path : "#{path}?#{URI.encode_www_form(params.map { |name, value| [name.to_s, value.to_s] }.sort)}"
  end

  def initialize
    @requests = []
    @unrecorded = []
    @downloads = []
  end

  def project_id
    self.class.meta.fetch("project_id")
  end

  def get(path, params = {})
    @requests << self.class.key(path, params)
    answer = self.class.answers[self.class.key(path, params)]
    # Mirror asks issue details with one or all associations; the full detail holds all.
    if answer.nil? && path.match?(%r{\Aissues/\d+\.json\z}) && params.keys.map(&:to_s) == ["include"]
      answer = self.class.answers[self.class.key(path, "include" => FULL_DETAIL)]
    end
    # The source refuses its users' details whatever IDs are asked.
    answer ||= self.class.answers[path] if path.end_with?("/mirror/source/users.json")
    unless answer
      @unrecorded << self.class.key(path, params)
      raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{path}"
    end
    raise RedmineMirror::Error, answer.fetch("error") if answer["error"]
    # Callers may change what they receive (tests do): each request gets its own copy.
    JSON.parse(JSON.generate(answer.fetch("body")))
  end

  def issue_detail(id)
    get("issues/#{Integer(id)}.json", "include" => FULL_DETAIL).fetch("issue")
  end

  # Same pagination as RedmineMirror::Client.
  def each_record(collection, params)
    return enum_for(__method__, collection, params) unless block_given?
    offset = 0
    loop do
      page = get("#{collection}.json", params.merge("offset" => offset, "limit" => 100))
      records = page.fetch(collection)
      records.each { |record| yield record }
      offset += records.length
      break if offset >= Integer(page.fetch("total_count")) || records.empty?
    end
  end

  # Files over 100 KB were recorded by size only: their bytes are generated, so imports
  # still check the size the source declares.
  def download_attachment(id, max_bytes: 32 * 1024 * 1024, path: nil)
    key = path || "attachments/download/#{Integer(id)}"
    @downloads << key
    file = self.class.files[key] or raise RedmineMirror::Error, "Redmine API returned HTTP 404 for GET #{key}"
    raise RedmineMirror::Error, file.fetch("error") if file["error"]
    size = file["size"] || File.size(File.join(DIRECTORY, "files", file.fetch("file")))
    raise RedmineMirror::Error, "Attachment exceeds the import limit of #{max_bytes / 1024} KB" if size > max_bytes
    file["size"] ? ("mirror-demo " * (size / 12 + 1)).byteslice(0, size).b : File.binread(File.join(DIRECTORY, "files", file.fetch("file")))
  end
end
