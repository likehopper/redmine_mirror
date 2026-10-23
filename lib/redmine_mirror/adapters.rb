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

require File.join(File.dirname(__FILE__), "adapters/base")
require File.join(File.dirname(__FILE__), "adapters/users")
require File.join(File.dirname(__FILE__), "adapters/issues")
require File.join(File.dirname(__FILE__), "adapters/time_entries")

require File.join(File.dirname(__FILE__), "adapters/issue_children")
require File.join(File.dirname(__FILE__), "adapters/journals")
require File.join(File.dirname(__FILE__), "adapters/attachments")

require File.join(File.dirname(__FILE__), "adapters/relations")

require File.join(File.dirname(__FILE__), "adapters/project_references")

require File.join(File.dirname(__FILE__), "adapters/issue_state")
require File.join(File.dirname(__FILE__), "adapters/hierarchy")
require File.join(File.dirname(__FILE__), "adapters/watchers")
require File.join(File.dirname(__FILE__), "adapters/custom_fields")
require File.join(File.dirname(__FILE__), "adapters/wiki")
require File.join(File.dirname(__FILE__), "adapters/members")
require File.join(File.dirname(__FILE__), "adapters/documents")
require File.join(File.dirname(__FILE__), "adapters/files")
require File.join(File.dirname(__FILE__), "adapters/news")
