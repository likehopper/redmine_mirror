# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/adapters.rb
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
# Load shared adapter contracts before concrete REST and native-model adapters.

require_relative "adapters/base"
require_relative "adapters/users"
require_relative "adapters/issues"
require_relative "adapters/time_entries"

require_relative "adapters/issue_children"
require_relative "adapters/journals"
require_relative "adapters/attachments"

require_relative "adapters/relations"

require_relative "adapters/project_references"

require_relative "adapters/issue_state"
require_relative "adapters/hierarchy"
require_relative "adapters/watchers"
require_relative "adapters/custom_fields"
