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
    # Without an administrator's fallback for users, a source user with neither a
    # correspondence, an account with the same email nor a single namesake is anonymized.
    BuiltInRule = Struct.new(:reference_type, :source_key, :source_url, :mode, :destination_id, keyword_init: true)
    USER_FALLBACK = BuiltInRule.new(reference_type: "user", source_key: nil, source_url: nil, mode: "anonymous", destination_id: nil).freeze

    def built_in_user_fallback?(rules)
      rules.none? { |rule| rule.reference_type == "user" && rule.source_key.nil? }
    end
    REQUIRED_COLUMNS = %w[type source_name destination].freeze

    # Whether the defaults fill this project by themselves (catalog refresh, administrator's
    # "apply"). The project's own buttons apply them whatever this choice.
    def automatic?(setting)
      MirrorDefaultMapping.schema_current? && setting.use_default_mappings
    end

    # Fill the project's references that have no correspondence yet, after its source
    # references were read. A rule for the source URL wins over a rule for any source. The
    # fallback only takes references the project uses, and leaves those with a single local
    # namesake to the form's suggestion. With `reset`, a reference whose name has a default
    # takes it even when it already has a correspondence (the fallback never replaces one).
    # Returns the number of correspondences saved.
    def apply(setting, reset: false)
      return 0 unless MirrorDefaultMapping.schema_current?
      rules = MirrorDefaultMapping.where(source_url: [nil, setting.source_url]).to_a
      rules << USER_FALLBACK if built_in_user_fallback?(rules)
      project = setting.project
      catalog = setting.source_catalog
      existing = project.mirror_reference_mappings.to_a.index_by { |row| [row.reference_type, row.source_id.to_s] }
      saved = 0
      setting.mapping_tables.each do |table|
        table_rules = rules.select { |rule| rule.reference_type == table.key }
        next if table_rules.empty?
        records = candidates(table, project)
        names = NameMatch.index(records.flat_map { |record| LocalizedNames.record_names(table.key, record).map { |name| [name, record.id.to_s] } })
        used = catalog["#{table.key}_used"]
        catalog.fetch(table.key, {}).each do |source_id, name|
          row = existing[[table.key, source_id]]
          next if row && !reset
          source_names = LocalizedNames.source_names(catalog, table.key, source_id, name)
          rule = pick(table_rules, source_names.map { |source_name| NameMatch.key(source_name) }, setting.source_url)
          namesake = source_names.any? { |source_name| NameMatch.suggest(source_name, names) }
          if rule.nil? && row.nil? && (used.nil? || used.include?(source_id)) && !namesake &&
             !(table.key == "user" && email_account?(catalog, source_id))
            rule = pick(table_rules, nil, setting.source_url)
          end
          next unless rule
          destination = rule.mode == "existing" ? local_id(rule.destination_id, records) : nil
          next if rule.mode == "existing" && destination.nil?
          if row && row.mode == rule.mode && row.destination_id == destination
            row.update_column(:from_default, true) unless row.from_default
            next
          end
          # A destination the project refuses (a field it cannot use) stays to map by hand.
          row ||= MirrorReferenceMapping.new(project: project, reference_type: table.key, source_id: Integer(source_id))
          row.assign_attributes(mode: rule.mode, destination_id: destination, from_default: true)
          saved += 1 if row.save
        end
      end
      saved + apply_values(setting, rules, reset: reset)
    end

    # Custom field list values: per source field mapped to a local list field, each source
    # value without a correspondence takes the default for its name, else the fallback.
    def apply_values(setting, rules, reset: false)
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
          current = values.dig(source_id, key).presence
          next if current && !reset
          name = value.fetch("label", value.fetch("value")).to_s
          rule = pick(field_rules, NameMatch.key(name), setting.source_url)
          rule ||= pick(field_rules, nil, setting.source_url) unless current || NameMatch.suggest(name, names)
          next unless rule && choices.any? { |_, id| id == rule.destination_value }
          next if current == rule.destination_value
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

    # Fill every configured project that uses the defaults, from the source references it
    # already read, without reading the sources again.
    def apply_all
      MirrorProjectSetting.where(catalog_status: [nil, "ready"], use_default_mappings: true).preload(:project).to_a.sum { |setting| apply(setting) }
    end

    def pick(rules, keys, url)
      keys = [keys] unless keys.is_a?(Array)
      matching = rules.select { |rule| keys.include?(rule.source_key) }
      scoped = matching.select { |rule| rule.source_url == url }
      matching = scoped.any? ? scoped : matching.select { |rule| rule.source_url.nil? }
      signatures = matching.group_by { |rule| [rule.mode, rule.destination_id, rule.destination_value, rule.custom_field_id] }
      signatures.one? ? signatures.values.first.first : nil
    end

    # A local account has the email the source shares for this user: the form proposes it.
    def email_account?(catalog, source_id)
      mail = catalog.dig("user_details", source_id.to_s, "mail").to_s.strip
      !mail.empty? && EmailAddress.where("LOWER(address) = ?", mail.downcase).exists?
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

    # The outcome of an import: the defaults saved, and each refused line with its number,
    # its message and its cells, to give the person back the lines to correct.
    ImportResult = Struct.new(:saved, :errors, :headers, keyword_init: true) do
      def messages
        errors.map { |error| error[:line] ? "#{error[:line]}: #{error[:message]}" : error[:message] }
      end

      # The refused lines as a CSV file with an "error" column, to correct and import again.
      def rejected_csv
        CSV.generate(col_sep: ";") do |csv|
          csv << headers + ["error"]
          errors.each { |error| csv << error[:cells] + [error[:message]] if error[:cells] }
        end
      end
    end

    # Read a CSV file (header line, separator ";", "," or tab). Each line adds a default or
    # replaces the one with the same type, field, source URL and name. Every line is checked
    # first. On any error nothing is saved, unless `partial` asks to save the valid lines
    # and skip the others. Every error is returned with its line number.
    def import(text, partial: false)
      text = text.to_s.dup.force_encoding("UTF-8").sub(/\A\uFEFF/, "")
      raise Error, "The file is not UTF-8" unless text.valid_encoding?
      separator = [";", "\t", ","].max_by { |candidate| text.lines.first.to_s.count(candidate) }
      rows = CSV.parse(text, col_sep: separator, headers: true)
      headers = rows.headers.map(&:to_s)
      missing = REQUIRED_COLUMNS - headers.map { |header| header.strip.downcase }
      raise Error, "Missing columns: #{missing.join(', ')}" if missing.any?
      errors = []
      lines = {}
      records = rows.each_with_index.filter_map do |row, index|
        refuse = ->(message) { errors << { line: index + 2, message: message, cells: row.fields.map(&:to_s) }; nil }
        values = row.to_h.transform_keys { |header| header.to_s.strip.downcase }.transform_values { |value| value.to_s.strip.presence }
        next if values.values.compact.empty?
        rule = build(values)
        identity = [rule.reference_type, rule.custom_field_id, rule.source_url, rule.source_key]
        next refuse.call("same type and source name as line #{lines[identity]}") if lines[identity]
        lines[identity] = index + 2
        next rule if rule.valid?
        refuse.call(rule.errors.full_messages.to_sentence)
      rescue Error => error
        refuse.call(error.message)
      end
      return ImportResult.new(saved: 0, errors: errors, headers: headers) if errors.any? && !partial
      MirrorDefaultMapping.transaction { records.each(&:save!) }
      ImportResult.new(saved: records.size, errors: errors, headers: headers)
    rescue CSV::MalformedCSVError => error
      ImportResult.new(saved: 0, errors: [{ message: error.message }], headers: [])
    end

    def build(values)
      type = values["type"].to_s.downcase
      raise Error, "Unknown type #{values['type']}" unless MirrorDefaultMapping::TYPES.include?(type)
      field = nil
      if type == "custom_field_value"
        field = find_by_name(MirrorDefaultMapping.list_fields, values["custom_field"], type: "custom_field") or raise Error, "Unknown custom field #{values['custom_field']}"
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
      elsif %w[ignore anonymous].include?(destination.downcase) || MirrorDefaultMapping.table(type)&.extra_choices&.include?(destination.downcase)
        rule.mode, rule.destination_id, rule.destination_value = destination.downcase, nil, nil
      else
        record = find_by_name(MirrorDefaultMapping.destinations(type), destination, type: type) or raise Error, "Unknown destination #{destination}"
        rule.mode, rule.destination_id, rule.destination_value = "existing", record.id, nil
      end
      rule
    end

    # "#12" is an ID; otherwise the exact name, its login for a user, then the name written
    # differently when only one record has it.
    def find_by_name(records, text, type: nil)
      text = text.to_s.strip
      return nil if text.empty?
      return records.find { |record| record.id == Integer(text[1..-1]) } if text.match?(/\A#\d+\z/)
      exact = records.select { |record| record.name.to_s.casecmp?(text) }
      return exact.first if exact.one?
      logins = records.select { |record| record.respond_to?(:login) && record.login.to_s.casecmp?(text) }
      return logins.first if logins.one?
      found = records.select do |record|
        (type ? LocalizedNames.record_names(type, record) : [record.name]).any? { |name| NameMatch.key(name) == NameMatch.key(text) }
      end
      found.one? ? found.first : nil
    end
  end
end
