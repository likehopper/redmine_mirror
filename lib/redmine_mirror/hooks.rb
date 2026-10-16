# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/hooks.rb
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
# Expose the mapped source issue on native issue pages for authorized Mirror managers.

module RedmineMirror
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_issues_show_details_bottom, partial: "mirror/issue_origin"
  end
end
