# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror.rb
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
# Load adapter implementations and register the built-in synchronization modules.

# Release tooling (scripts/package.sh) and plugin registration read this version. It
# lives here, not in lib/redmine_mirror/version.rb: Zeitwerk would require that file to
# define RedmineMirror::Version, which would hide Redmine's Version model in this namespace.
module RedmineMirror
  VERSION = "1.0.0-beta.3"
  # Contract between Mirror and external adapters. Increase only on incompatible
  # changes to Adapters::Base, MappingTable or the registration rules.
  ADAPTER_API_VERSION = 1
end

require "json"
require "digest"
require_relative "redmine_mirror/client"
require_relative "redmine_mirror/registry"
require_relative "redmine_mirror/text_format"
require_relative "redmine_mirror/mapping_table"
require_relative "redmine_mirror/adapters"
require_relative "redmine_mirror/source_catalog"
require_relative "redmine_mirror/project_patch"
require_relative "redmine_mirror/runner"
require_relative "redmine_mirror/database_store"
require_relative "redmine_mirror/synchronization"
module RedmineMirror
  REGISTRY = Registry.new

  # Register an adapter shipped by another Redmine plugin. See doc/ADAPTERS.md.
  def self.register_adapter(adapter)
    REGISTRY.register(adapter)
  end

  users = Adapters::Users.new
  REGISTRY.register(users)
  REGISTRY.register(Adapters::Issues.new(users: users))
  REGISTRY.register(Adapters::TimeEntries.new(users: users))
  REGISTRY.register(Adapters::Journals.new)
  REGISTRY.register(Adapters::Attachments.new)
  REGISTRY.register(Adapters::Relations.new)
  REGISTRY.register(Adapters::Categories.new)
  REGISTRY.register(Adapters::Versions.new)
  REGISTRY.register(Adapters::Hierarchy.new)
  REGISTRY.register(Adapters::Watchers.new)
  REGISTRY.register(Adapters::CustomFields.new)
end
