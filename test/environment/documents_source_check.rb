# frozen_string_literal: true
# File: redmine_mirror/test/environment/documents_source_check.rb
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
# After documents_smoke.rb, check on the source what Mirror source logged.

abort "Disposable source only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable" && ENV["MIRROR_ROLE"] == "source"
project = Project.find_by!(identifier: "mirror-documents-demo")
sessions = project.mirror_source_accesses.sessions.to_a
raise "No Mirror source session logged" if sessions.empty?
purposes = sessions.map(&:purpose).compact.uniq.sort
raise "Purposes #{purposes.inspect}" unless (%w[preview references synchronization] - purposes).empty?
synchronization = project.mirror_source_accesses.where(purpose: "synchronization")
downloads = synchronization.where(action: "download")
raise "File transfers not logged" unless downloads.count == 2 && downloads.sum(:bytes).positive?
raise "Private file metadata logged" unless downloads.pluck(:details).all? { |details| JSON.parse(details) == { "kind" => "documents" } }
raise "Account not logged" unless project.mirror_source_accesses.where(user_id: nil).none?
puts "Documents source check passed: #{sessions.size} sessions (#{purposes.join(', ')}), private-free file transfer metadata and account logged"
