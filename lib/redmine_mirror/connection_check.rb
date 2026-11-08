# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/connection_check.rb
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
# Check a source connection before it is saved.

module RedmineMirror
  # Whose API key it is, which project it designates and what that project offers, in a
  # few small reads made during the web request. The catalog stays the worker's job.
  class ConnectionCheck
    # Redmine 4.0 cannot filter projects by parent: subprojects are found in the projects
    # the key sees, read up to this many pages of 100.
    PROJECT_PAGES = 10

    def initialize(client:, project_reference:)
      @client, @project_reference = client, project_reference
    end

    # A Hash: "account", "project" (id, identifier, name), "source_modules", "members"
    # (count, nil when unreadable), "subprojects" (id, identifier, name; nil when
    # unreadable), "subprojects_complete"; or "error" ("account" or "project") with
    # "detail" when the key or the project is refused.
    def run
      user = read("account") { @client.get("users/current.json").fetch("user") }
      project = read("project") do
        @client.get("projects/#{@project_reference}.json", "include" => "enabled_modules").fetch("project")
      end
      id = Integer(project.fetch("id"))
      subprojects, complete = subprojects_of(id)
      name = [user["firstname"], user["lastname"]].join(" ").strip
      { "account" => name.empty? ? user["login"].to_s : name,
        "project" => { "id" => id, "identifier" => project["identifier"].to_s, "name" => project["name"].to_s },
        "source_modules" => Array(project["enabled_modules"]).map { |entry| entry["name"].to_s },
        "members" => members_count(id), "subprojects" => subprojects, "subprojects_complete" => complete }
    rescue Failure => failure
      { "error" => failure.step, "detail" => failure.message }
    end

    private

    class Failure < StandardError
      attr_reader :step

      def initialize(step, message)
        super(message)
        @step = step
      end
    end

    def read(step)
      yield
    rescue Error, KeyError, TypeError, ArgumentError => error
      raise Failure.new(step, error.message)
    end

    # Members are optional to the check: their list needs a permission the key may lack.
    def members_count(project_id)
      Integer(@client.get("projects/#{project_id}/memberships.json", "limit" => 1).fetch("total_count"))
    rescue Error, KeyError, TypeError, ArgumentError
      nil
    end

    def subprojects_of(project_id)
      found = []
      offset = 0
      PROJECT_PAGES.times do
        page = @client.get("projects.json", "offset" => offset, "limit" => 100)
        records = page.fetch("projects")
        records.each do |record|
          next unless record.dig("parent", "id").to_i == project_id
          found << { "id" => Integer(record.fetch("id")), "identifier" => record["identifier"].to_s, "name" => record["name"].to_s }
        end
        offset += records.length
        return [found, true] if records.empty? || offset >= Integer(page.fetch("total_count"))
      end
      [found, false]
    rescue Error, KeyError, TypeError, ArgumentError
      [nil, false]
    end
  end
end
