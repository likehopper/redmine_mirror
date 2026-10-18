# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/authorization.rb
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
# Controller checks for the three Mirror levels: view, run and configure.

module RedmineMirror
  # Redmine's authorize only knows permissions; configuring also follows the right to
  # enable the project's modules, so each controller states the level it needs.
  module Authorization
    LEVELS = {
      view: ->(project) { RedmineMirror.runner?(project) || User.current.allowed_to?(:view_mirror, project) },
      run: ->(project) { RedmineMirror.runner?(project) },
      manage: ->(project) { RedmineMirror.manager?(project) }
    }.freeze

    private

    def authorize_mirror(level)
      LEVELS.fetch(level).call(@project) ? true : deny_access
    end
  end
end
