# frozen_string_literal: true
# File: redmine_mirror/test/compatibility/plugins/zzz_mirror_compat_alias/init.rb
#
# Redmine Mirror - modular project import and asynchronous replication.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Test-only plugin installed by the compatibility runner: alias_method chain, loaded after Mirror (like redmine_smile_project_enumerations_custom_field_format).
# It adds a project settings tab, as some real-world plugins do, so the suite checks
# that Mirror's settings tab and theirs coexist.

require "redmine"
Redmine::Plugin.register :zzz_mirror_compat_alias do
  name "Mirror compatibility fixture (zzz_mirror_compat_alias)"
  author "Redmine Mirror contributors"
  version "1.0.0"
end
ProjectsHelper.module_eval do
  unless method_defined?(:project_settings_tabs_without_zzz_mirror_compat)
    alias_method :project_settings_tabs_without_zzz_mirror_compat, :project_settings_tabs
    def project_settings_tabs_with_zzz_mirror_compat
      project_settings_tabs_without_zzz_mirror_compat << { name: "zzz_mirror_compat_alias", action: :edit_project, partial: "mirror_compat/zzz_mirror_compat_alias", label: :label_settings }
    end
    alias_method :project_settings_tabs, :project_settings_tabs_with_zzz_mirror_compat
  end
end
