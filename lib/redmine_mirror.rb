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
  VERSION = "1.0.0-beta.31"
  # Contract between Mirror and external adapters. Increase only on incompatible
  # changes to Adapters::Base, MappingTable or the registration rules.
  ADAPTER_API_VERSION = 1
end

require "json"
require "digest"
# Same path as Redmine's autoloader, so symlinked plugin directories load once (init.rb).
require File.join(File.dirname(__FILE__), "redmine_mirror/client")
require File.join(File.dirname(__FILE__), "redmine_mirror/registry")
require File.join(File.dirname(__FILE__), "redmine_mirror/text_format")
require File.join(File.dirname(__FILE__), "redmine_mirror/mapping_table")
require File.join(File.dirname(__FILE__), "redmine_mirror/name_match")
require File.join(File.dirname(__FILE__), "redmine_mirror/default_mappings")
require File.join(File.dirname(__FILE__), "redmine_mirror/ai")
require File.join(File.dirname(__FILE__), "redmine_mirror/diagnosis")
require File.join(File.dirname(__FILE__), "redmine_mirror/adapters")
require File.join(File.dirname(__FILE__), "redmine_mirror/source_catalog")
require File.join(File.dirname(__FILE__), "redmine_mirror/project_patch")
require File.join(File.dirname(__FILE__), "redmine_mirror/projects_helper_patch")
require File.join(File.dirname(__FILE__), "redmine_mirror/authorization")
require File.join(File.dirname(__FILE__), "redmine_mirror/policy")
require File.join(File.dirname(__FILE__), "redmine_mirror/runner")
require File.join(File.dirname(__FILE__), "redmine_mirror/database_store")
require File.join(File.dirname(__FILE__), "redmine_mirror/synchronization")
require File.join(File.dirname(__FILE__), "redmine_mirror/source")
module RedmineMirror
  REGISTRY = Registry.new

  # Below Redmine 5 (Rails 5.2, Ruby 2.6), Mirror only runs as a source: Mirror source
  # shares what the REST API does not cover. Destinations need Redmine 5 or later.
  def self.source_only?
    Redmine::VERSION::MAJOR < 5
  end

  # Migrations keep the Rails 6.1 behaviour and also run on the Rails 5.2 of Redmine 4.
  def self.migration_version
    ActiveRecord::VERSION::MAJOR >= 6 ? 6.1 : 5.2
  end

  # Source Redmine URLs that non-administrators may connect to (plugin settings).
  def self.allowed_source_urls
    settings = Setting.plugin_redmine_mirror rescue {}
    settings.to_h.fetch("allowed_source_urls", "").to_s.lines.map { |line| line.strip.sub(%r{/+\z}, "") }.reject(&:empty?).uniq
  end

  # User custom field shown as the company next to local users: the one chosen in the
  # plugin settings, else a field named Company, Société, Entreprise or Organization.
  COMPANY_FIELD_NAMES = /\A(?:company|soci[ée]t[ée]|entreprise|organi[sz]ation)\z/i

  def self.user_company_field
    id = (Setting.plugin_redmine_mirror rescue {}).to_h["user_company_field_id"].to_s
    return nil if id == "none"
    return UserCustomField.find_by(id: id) if id.present?
    UserCustomField.sorted.detect { |field| field.name.to_s.strip.match?(COMPANY_FIELD_NAMES) }
  end

  # Accounts kept for the history but not active: locked, or registered and awaiting
  # activation (created from a Mirror source). Redmine refuses them as new values.
  def self.inactive_user?(id)
    id.is_a?(Integer) && User.where(id: id, status: [User::STATUS_LOCKED, User::STATUS_REGISTERED]).exists?
  end

  def self.allowed_source_url?(url)
    allowed_source_urls.include?(url.to_s.strip.sub(%r{/+\z}, ""))
  end

  # Configuring Mirror: its permission, or the right to enable the project's modules.
  def self.manager?(project, user = User.current)
    return false unless project&.module_enabled?(:mirror)
    user.allowed_to?(:manage_mirror, project) || user.allowed_to?(:select_project_modules, project)
  end

  # Choosing any account of the instance in the user mappings, for the Members module.
  def self.members_manager?(project, user = User.current)
    return false unless project&.mirror_project_setting&.selected_modules.to_a.include?("project_members")
    user.admin? || user.allowed_to?(:manage_members, project)
  end

  # Creating registered accounts (awaiting activation) from the users a source shares:
  # the administrator's switch, then the right to manage the project's members.
  def self.user_creation?(project, user = User.current)
    return false unless (Setting.plugin_redmine_mirror rescue {}).to_h["user_creation_enabled"].to_s == "1"
    user.admin? || user.allowed_to?(:manage_members, project)
  end

  # Launching executions and resolving conflicts; configuring includes it.
  def self.runner?(project, user = User.current)
    manager?(project, user) || user.allowed_to?(:run_mirror, project)
  end

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
  REGISTRY.register(Adapters::Wiki.new)
  REGISTRY.register(Adapters::Members.new)
  REGISTRY.register(Adapters::Documents.new)
  REGISTRY.register(Adapters::Files.new)
  REGISTRY.register(Adapters::News.new)
  REGISTRY.register(Adapters::IssueTags.new)
  REGISTRY.register(Adapters::AgileSprints.new)
  REGISTRY.register(Adapters::AgileIssues.new)
  REGISTRY.register(Adapters::ProjectQueries.new)
end
