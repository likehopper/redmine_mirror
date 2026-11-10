# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/plain_flash.rb
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
# Escape the flash messages of Mirror controllers.

module RedmineMirror
  # Redmine prints every flash message as HTML (render_flash_messages). Mirror messages are
  # plain text that can carry source data, such as project or user names and the error
  # texts of a source API: the messages set by the action are escaped once it has run.
  # Those carried over from the previous request are left as they are.
  module PlainFlash
    def self.included(base)
      base.before_action :remember_mirror_flash
      base.after_action :escape_mirror_flash
    end

    private

    def remember_mirror_flash
      @mirror_flash_before = flash.to_hash.dup
    end

    def escape_mirror_flash
      flash.to_hash.each do |key, value|
        next unless value.is_a?(String) && !value.html_safe?
        next if @mirror_flash_before && @mirror_flash_before[key].equal?(value)
        flash[key] = ERB::Util.h(value)
      end
    end
  end
end
