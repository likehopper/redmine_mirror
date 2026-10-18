# frozen_string_literal: true
# File: redmine_mirror/test/compatibility/plugins/zzz_mirror_compat_prepend/init.rb
#
# Redmine Mirror - modular project import and asynchronous replication.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Test-only plugin installed by the compatibility runner: Module#prepend, loaded after Mirror (like Redmine Reporting and Redmine SLA).
# It adds a project settings tab, as some real-world plugins do, so the suite checks
# that Mirror's settings tab and theirs coexist.

require "redmine"
Redmine::Plugin.register :zzz_mirror_compat_prepend do
  name "Mirror compatibility fixture (zzz_mirror_compat_prepend)"
  author "Redmine Mirror contributors"
  version "1.0.0"
end
module ZzzMirrorCompatPrepend
  def project_settings_tabs
    super << { name: "zzz_mirror_compat_prepend", action: :edit_project, partial: "mirror_compat/zzz_mirror_compat_prepend", label: :label_settings }
  end
end
ProjectsHelper.prepend(ZzzMirrorCompatPrepend) unless ProjectsHelper < ZzzMirrorCompatPrepend
