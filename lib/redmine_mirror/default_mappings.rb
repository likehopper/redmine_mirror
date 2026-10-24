# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/default_mappings.rb
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
# Save the administrator's default correspondences into a project, and read or write them
# as CSV (doc/DEFAULT_MAPPINGS.md).

require "csv"

module RedmineMirror
  module DefaultMappings
    module_function

    CSV_COLUMNS = %w[type source_name source_url destination custom_field].freeze
    REQUIRED_COLUMNS = %w[type source_name destination].freeze

    # Fill the project's references that have no correspondence yet, after its source
    # references were read. A rule for the source URL wins over a rule for any source. The
    # fallback only takes references the project uses, and leaves those with a single local
    # namesake to the form's suggestion. Returns the number of correspondences saved.
    def apply(setting)
      return 0 unless MirrorDefaultMapping.schema_current?
      rules = MirrorDefaultMapping.where(source_url: [nil, setting.source_url]).to_a
      return 0 if rules.empty?
      project = setting.project
      catalog = setting.source_catalog
      mapped = project.mirror_reference_mappings.pluck(:reference_type, :source_id).map { |kind, id| [kind, id.to_s] }.to_set
      saved = 0
      setting.mapping_tables.each do |table|
        table_rules = rules.select { |rule| rule.reference_type == table.key }
        next if table_rules.empty?
        records = candidates(table, project)
        names = NameMatch.index(records.map { |record| [record.name.to_s, record.id.to_s] })
        used = catalog["#{table.key}_used"]
        catalog.fetch(table.key, {}).each do |source_id, name|
          next if mapped.include?([table.key, source_id])
          rule = pick(table_rules, NameMatch.key(name), setting.source_url)
          if rule.nil? && (used.nil? || used.include?(source_id)) && !NameMatch.suggest(name, names)
            rule = pick(table_rules, nil, setting.source_url)
          end
          next unless rule
          destination = rule.mode == "existing" ? local_id(rule.destination_id, records) : nil
          next if rule.mode == "existing" && destination.nil?
          # A destination the project refuses (a field it cannot use) stays to map by hand.
          row = MirrorReferenceMapping.new(project: project, reference_type: table.key, source_id: Integer(source_id),
            mode: rule.mode, destination_id: destination, from_default: true)
          saved += 1 if row.save
        end
      end
      saved + apply_values(setting, rules)
    end

    # Custom field list values: per source field mapped to a local list field, each source
    # value without a correspondence takes the default for its name, else the fallback.
    def apply_values(setting, rules)
      value_rules = rules.select { |rule| rule.reference_type == "custom_field_value" }
      return 0 if value_rules.empty? || !setting.selected_modules.include?("issue_custom_fields")
      project = setting.project
      adapter = Adapters::CustomFields.new
      definitions = setting.source_catalog.fetch("custom_field_definitions", {})
      fields = project.mirror_reference_mappings.where(reference_type: "custom_field", mode: "existing").pluck(:source_id, :destination_id).to_h
      options = setting.module_options
      values = options.dig(adapter.key, "value_mappings") || {}
      saved = 0
      definitions.each do |source_id, definition|
        field = project.all_issue_custom_fields.find { |candidate| candidate.id == fields[Integer(source_id)] }
        next unless field && adapter.list_values?(definition, field)
        field_rules = value_rules.select { |rule| rule.custom_field_id == field.id }
        next if field_rules.empty?
        choices = MirrorDefaultMapping.value_choices(field)
        names = NameMatch.index(choices)
        definition.fetch("possible_values", []).each do |value|
          key = adapter.value_key(value.fetch("value"))
          next if values.dig(source_id, key).present?
          name = value.fetch("label", value.fetch("value")).to_s
          rule = pick(field_rules, NameMatch.key(name), setting.source_url)
          rule ||= pick(field_rules, nil, setting.source_url) unless NameMatch.suggest(name, names)
          next unless rule && choices.any? { |_, id| id == rule.destination_value }
          (values[source_id] ||= {})[key] = rule.destination_value
          saved += 1
        end
      end
      if saved.positive?
        options[adapter.key] = (options[adapter.key] || {}).merge("value_mappings" => values)
        setting.update_columns(module_options: JSON.generate(options))
      end
      saved
    end

    # Fill every configured project from the source references it already read, without
    # reading the sources again.
    def apply_all
      MirrorProjectSetting.where(catalog_status: [nil, "ready"]).preload(:project).to_a.sum { |setting| apply(setting) }
    end

    def pick(rules, key, url)
      matching = rules.select { |rule| rule.source_key == key }
      matching.find { |rule| rule.source_url == url } || matching.find { |rule| rule.source_url.nil? }
    end

    # The project's choices for a table. Any account may be a default (a generic account
    # need not be a member); the project's records are read without the current user.
    def candidates(table, project)
      table.key == "user" ? MirrorDefaultMapping.destinations("user") : table.local_records(project).to_a
    end

    # A project may override a shared activity: the override stands for it.
    def local_id(id, records)
      record = records.find { |candidate| candidate.id == id } ||
               records.find { |candidate| candidate.respond_to?(:parent_id) && candidate.parent_id == id }
      record&.id
    end

    def to_csv(rules)
      CSV.generate(col_sep: ";") do |csv|
        csv << CSV_COLUMNS
        rules.each do |rule|
          destination = if rule.reference_type == "custom_field_value" then rule.destination_value_label || rule.destination_value
                        elsif rule.mode == "existing" then rule.destination&.name || "##{rule.destination_id}"
                        else rule.mode
                        end
          csv << [rule.reference_type, rule.source_name, rule.source_url, destination, rule.custom_field&.name]
        end
      end
    end

    # Read a CSV file (header line, separator ";", "," or tab). Each line adds a default or
    # replaces the one with the same type, field, source URL and name. Every line is checked
    # first: on any error nothing is saved, and the errors are returned with line numbers.
    def import(text)
      text = text.to_s.dup.force_encoding("UTF-8").sub(/\A\uFEFF/, "")
      raise Error, "The file is not UTF-8" unless text.valid_encoding?
      separator = [";", "\t", ","].max_by { |candidate| text.lines.first.to_s.count(candidate) }
      rows = CSV.parse(text, col_sep: separator, headers: true)
      missing = REQUIRED_COLUMNS - rows.headers.compact.map { |header| header.strip.downcase }
      raise Error, "Missing columns: #{missing.join(', ')}" if missing.any?
      errors = []
      lines = {}
      records = rows.each_with_index.filter_map do |row, index|
        values = row.to_h.transform_keys { |header| header.to_s.strip.downcase }.transform_values { |value| value.to_s.strip.presence }
        next if values.values.compact.empty?
        rule = build(values)
        identity = [rule.reference_type, rule.custom_field_id, rule.source_url, rule.source_key]
        if (line = lines[identity])
          errors << "#{index + 2}: same type and source name as line #{line}"
          next
        end
        lines[identity] = index + 2
        next rule if rule.valid?
        errors << "#{index + 2}: #{rule.errors.full_messages.to_sentence}"
        nil
      rescue Error => error
        errors << "#{index + 2}: #{error.message}"
        nil
      end
      return [0, errors] if errors.any?
      MirrorDefaultMapping.transaction { records.each(&:save!) }
      [records.size, []]
    rescue CSV::MalformedCSVError => error
      [0, [error.message]]
    end

    def build(values)
      type = values["type"].to_s.downcase
      raise Error, "Unknown type #{values['type']}" unless MirrorDefaultMapping::TYPES.include?(type)
      field = nil
      if type == "custom_field_value"
        field = find_by_name(MirrorDefaultMapping.list_fields, values["custom_field"]) or raise Error, "Unknown custom field #{values['custom_field']}"
      end
      key = values["source_name"] && NameMatch.key(values["source_name"]).presence
      rule = MirrorDefaultMapping.find_or_initialize_by(reference_type: type, custom_field_id: field&.id,
        source_url: MirrorDefaultMapping.normalize_url(values["source_url"]), source_key: key)
      rule.source_name = values["source_name"]
      destination = values["destination"].to_s
      if field
        choices = MirrorDefaultMapping.value_choices(field)
        value = choices.find { |label, id| [label, id].include?(destination) } ||
                choices.find { |label, _| NameMatch.key(label) == NameMatch.key(destination) }
        raise Error, "Unknown value #{destination} of #{field.name}" unless value
        rule.mode, rule.destination_id, rule.destination_value = "existing", nil, value.last
      elsif %w[ignore anonymous].include?(destination.downcase)
        rule.mode, rule.destination_id, rule.destination_value = destination.downcase, nil, nil
      else
        record = find_by_name(MirrorDefaultMapping.destinations(type), destination) or raise Error, "Unknown destination #{destination}"
        rule.mode, rule.destination_id, rule.destination_value = "existing", record.id, nil
      end
      rule
    end

    # "#12" is an ID; otherwise the exact name, its login for a user, then the name written
    # differently when only one record has it.
    def find_by_name(records, text)
      text = text.to_s.strip
      return nil if text.empty?
      return records.find { |record| record.id == Integer(text[1..-1]) } if text.match?(/\A#\d+\z/)
      records.find { |record| record.name.to_s.casecmp?(text) } ||
        records.find { |record| record.respond_to?(:login) && record.login.to_s.casecmp?(text) } ||
        records.select { |record| NameMatch.key(record.name) == NameMatch.key(text) }.then { |found| found.one? ? found.first : nil }
    end
  end
end
