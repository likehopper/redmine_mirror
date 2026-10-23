# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/source_catalog.rb
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
# Discover source references and historical identities for project-scoped mapping forms.

module RedmineMirror
  class SourceCatalog
    def initialize(client:, project_id:, adapters:)
      @client, @project_id, @adapters = client, project_id, adapters
    end

    # Adapters declare their mapping tables before contributing references.
    # Preserve field metadata separately from labels for compatibility checks.
    # progress, when given, receives (step, steps, module key, records read so far).
    def fetch(progress: nil)
      @client.get("projects/#{Integer(@project_id)}.json")
      tables = {}
      used = Hash.new { |hash, key| hash[key] = [] }
      formats = Hash.new(0)
      statistics = {}
      @adapters.each_with_index do |adapter, index|
        counts = statistics[adapter.key] = { "records" => 0 }
        progress&.call(index + 1, @adapters.size, adapter.key, 0)
        adapter.mapping_tables.each { |table| tables[table.key] ||= {} }
        adapter.catalog_references(@client, @project_id).each do |kind, references|
          raise Error, "Undeclared module mapping table" unless tables.key?(kind)
          references.each do |reference|
            id = Integer(reference.fetch("id"))
            tables[kind][id.to_s] = reference.fetch("name", "##{id}")
            table = adapter.mapping_tables.find { |entry| entry.key == kind }
            if table && !table.metadata_fields.empty?
              (tables["#{kind}_definitions"] ||= {})[id.to_s] = reference.select { |key, _| table.metadata_fields.include?(key) }
            end
          end
        end
        adapter.records(@client, @project_id).each_with_index do |record, count|
          progress&.call(index + 1, @adapters.size, adapter.key, count + 1)
          next unless record.fetch("project").fetch("id").to_i == @project_id.to_i
          counts["records"] += 1
          adapter.catalog_statistics(record).each { |name, value| counts[name] = counts.fetch(name, 0) + value }
          # Historical authors and observers may not be project members. Discover
          # their remote identities without creating any destination accounts.
          if tables.key?("user")
            adapter.referenced_users(record).each do |reference|
              id = Integer(reference.fetch("id"))
              tables["user"][id.to_s] = reference.fetch("name", "##{id}")
            end
          end
          adapter.mapping_tables.each do |table|
            table.references(record).each do |reference|
              id = Integer(reference.fetch("id"))
              tables[table.key][id.to_s] = reference.fetch("name", "##{id}")
              used[table.key] << id.to_s
            end
          end
          adapter.text_samples(record).each do |text|
            format = TextFormat.detect(text.to_s)
            formats[format || "plain"] += 1 unless text.to_s.strip.empty?
          end
          adapter.used_references(record).each do |kind, ids|
            used[kind].concat(ids.map { |id| Integer(id).to_s }) if tables.key?(kind)
          end
        end
      end
      # "<table>_used" lists the source IDs that the project's records reference.
      used.each { |kind, ids| tables["#{kind}_used"] = ids.uniq.sort_by(&:to_i) }
      # Detected markup of descriptions and notes, shown next to the source text format.
      tables["text_formats"] = formats unless formats.empty?
      # Per module: records of the project and adapter statistics, with the time they
      # were read, compared with the destination in the module tabs.
      tables["module_statistics"] = statistics
      tables["read_at"] = Time.now.utc.iso8601
      tables
    end
  end
end
