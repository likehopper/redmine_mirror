# frozen_string_literal: true
# File: redmine_mirror/test/environment/reader_account.rb
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
# Dedicated, non-administrator source account for Mirror: read-only role on every
# source project, API key "3" * 40. Used by versions.sh with MIRROR_SOURCE_ACCOUNT=reader.

abort "Disposable test environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable"
abort "Source instance only" unless ENV["MIRROR_ROLE"] == "source"
role = Role.find_or_initialize_by(name: "Mirror reader")
# Everything Mirror reads, nothing it could change.
role.permissions = %i[view_issues view_private_notes view_time_entries view_issue_watchers]
role.issues_visibility = "all"
role.users_visibility = "all"
role.time_entries_visibility = "all" if role.respond_to?(:time_entries_visibility=)
role.save!
reader = User.find_by(login: "mirror-reader") || User.create!(login: "mirror-reader", firstname: "Mirror",
  lastname: "Reader", mail: "mirror-reader@example.invalid", admin: false,
  password: "Mirror-test-2026!", password_confirmation: "Mirror-test-2026!")
Project.where.not(status: Project::STATUS_ARCHIVED).find_each do |project|
  next if Member.exists?(project: project, user_id: reader.id)
  Member.create!(project: project, principal: reader, roles: [role])
end
token = Token.find_or_create_by!(user: reader, action: "api")
token.update!(value: "3" * 40)
puts "Source reader account ready on #{reader.memberships.count} projects"
