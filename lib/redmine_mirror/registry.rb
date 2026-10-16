# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/registry.rb
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
# Resolve adapter dependencies once and reject unknown modules or dependency cycles.

module RedmineMirror
  class Registry
    # Execution phases, in order. Requested modules are visited by phase, then
    # dependencies are inserted before the module that declares them.
    PHASES = %i[references default history].freeze
    KEY_FORMAT = /\A[a-z][a-z0-9_]{0,63}\z/

    def initialize
      @adapters = {}
    end

    # The key is persisted in settings and correspondences; reject adapters that
    # would be unreadable by the views or incompatible with this contract.
    def register(adapter)
      raise Error, "Invalid module key #{adapter.key.inspect}" unless adapter.key.is_a?(String) && adapter.key.match?(KEY_FORMAT)
      raise Error, "Duplicate module #{adapter.key}" if @adapters.key?(adapter.key)
      raise Error, "Module #{adapter.key} targets adapter API #{adapter.api_version}, Mirror provides #{ADAPTER_API_VERSION}" unless adapter.api_version == ADAPTER_API_VERSION
      raise Error, "Unknown phase #{adapter.phase.inspect} for module #{adapter.key}" unless PHASES.include?(adapter.phase)
      @adapters[adapter.key] = adapter
    end

    def keys
      @adapters.keys
    end

    def [](key)
      @adapters[key]
    end

    # Find a reference table declared by any registered adapter, for links and labels.
    def mapping_table(key)
      @adapters.each_value.lazy.flat_map(&:mapping_tables).find { |table| table.key == key }
    end

    # A depth-first dependency walk produces one ordered instance per adapter.
    # Project references precede issues; history follows current field preparation.
    def resolve(keys)
      ordered = []
      visiting = []
      visit = lambda do |key|
        raise Error, "Cyclic module dependency" if visiting.include?(key)
        adapter = @adapters.fetch(key) { raise Error, "Unknown module #{key}" }
        unless ordered.include?(adapter)
          visiting << key
          adapter.dependencies.each { |dependency| visit.call(dependency) }
          visiting.pop
          ordered << adapter
        end
      end
      keys.each_with_index.sort_by { |key, index| [PHASES.index(@adapters[key]&.phase) || 0, index] }.each { |key, _index| visit.call(key) }
      ordered
    end
  end
end
