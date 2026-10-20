# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_ai_usage.rb
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
# Requests and tokens sent to the AI API, per day, for the daily limit and the admin page.

class MirrorAiUsage < ActiveRecord::Base
  def self.today
    find_or_create_by!(day: Date.current)
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def self.requests_today
    where(day: Date.current).sum(:requests)
  end

  # Counts one more request, unless the daily limit is reached.
  def self.reserve!(limit)
    usage = today
    usage.with_lock do
      raise RedmineMirror::Ai::BudgetExhausted, "The daily limit of AI requests (#{limit}) is reached" if usage.requests >= limit
      usage.update_columns(requests: usage.requests + 1)
    end
  end

  def self.add_tokens!(tokens)
    where(id: today.id).update_all(["tokens = tokens + ?", tokens.to_i]) if tokens.to_i.positive?
  end
end
