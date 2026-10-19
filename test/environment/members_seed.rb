# frozen_string_literal: true
# File: redmine_mirror/test/environment/members_seed.rb
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
# Build disposable demo records for manual and API synchronization checks.

abort "Disposable source only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "source"
alice = User.find_by!(login: "alice")
leaver = User.find_by(login: "mirror-leaver") || User.create!(login: "mirror-leaver", firstname: "Lea", lastname: "Leaver",
  mail: "mirror-leaver@example.invalid", password: "Mirror-test-2026!", password_confirmation: "Mirror-test-2026!")
group = Group.find_by(lastname: "Mirror team") || Group.create!(lastname: "Mirror team")
project = Project.find_or_create_by!(identifier: "mirror-members-demo") do |row|
  row.name = "Mirror members fixtures"
  row.enabled_module_names = %w[issue_tracking]
end
{ alice => "Manager", leaver => "Reporter", group => "Developer" }.each do |principal, role|
  Member.find_or_create_by!(project: project, user_id: principal.id) { |row| row.roles = [Role.find_by!(name: role)] }
end
puts "Member fixtures ready: Alice (Manager), mirror-leaver (Reporter), group Mirror team (Developer)"
