# frozen_string_literal: true
# File: redmine_mirror/test/environment/incremental_source_seed.rb
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

abort "Disposable test environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable"
Setting.plugin_redmine_mirror = Setting.plugin_redmine_mirror.to_h.merge("source_enabled" => "1")
project = Project.find_by!(identifier: "mirror-demo")
project.enable_module!(:mirror_source)
MirrorSourceSetting.find_or_create_by!(project: project) { |row| row.shared_modules = [] }
puts "Incremental Mirror source enabled"
