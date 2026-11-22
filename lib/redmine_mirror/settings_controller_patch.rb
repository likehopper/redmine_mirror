# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/settings_controller_patch.rb
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
# Ask destinations for a complete pass when the administrator switches the change journal.

module RedmineMirror
  # Changes made while the journal is suspended are never recorded, and nothing tells a
  # destination about that gap: switching it either way asks every destination for a
  # complete pass at its next run (SourceChanges.require_full_resync).
  module SettingsControllerPatch
    def self.included(base)
      base.around_action :mirror_watch_change_journal, only: :plugin
    end

    private

    def mirror_watch_change_journal
      return yield unless request.post? && params[:id] == "redmine_mirror"
      was_enabled = RedmineMirror::Source.changes_enabled?
      yield
      RedmineMirror::SourceChanges.require_full_resync if RedmineMirror::Source.changes_enabled? != was_enabled
    end
  end
end
