# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/policy.rb
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
# Synchronization policy of the current run, read by the adapters.

module RedmineMirror
  module Policy
    module_function

    def with(source_wins:)
      previous = Thread.current[:redmine_mirror_source_wins]
      Thread.current[:redmine_mirror_source_wins] = !!source_wins
      yield
    ensure
      Thread.current[:redmine_mirror_source_wins] = previous
    end

    # Mirror mode: a local difference is overwritten and a local deletion recreated,
    # instead of being reported as a conflict.
    def source_wins?
      !!Thread.current[:redmine_mirror_source_wins]
    end

    # The message of a local difference: a conflict, unless the source wins.
    def local_change!(message)
      raise Error, message unless source_wins?
    end
  end
end
