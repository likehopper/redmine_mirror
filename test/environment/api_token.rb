# frozen_string_literal: true
# File: redmine_mirror/test/environment/api_token.rb
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
# Exercise Mirror behavior against the disposable Redmine environment.

abort "Disposable test environment only" unless ENV["MIRROR_TEST_ENVIRONMENT"] == "disposable"
admin = User.find_by!(login: "admin")
token = Token.find_or_create_by!(user: admin, action: "api")
# Redmine generates the token before creation; set the deterministic demo key afterwards.
token.update!(value: ENV.fetch("MIRROR_ROLE") == "source" ? "1" * 40 : "2" * 40)
