# frozen_string_literal: true
# File: redmine_mirror/app/models/mirror_ai_config.rb
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
# The instance's AI configuration (Administration > Mirror > AI), in its own table: the
# plugin settings page rewrites its whole hash and would drop an encrypted key.

class MirrorAiConfig < ActiveRecord::Base
  # Base URLs of the OpenAI-compatible APIs; "other" takes the URL entered.
  PROVIDERS = { "gemini" => "https://generativelanguage.googleapis.com/v1beta/openai",
                "ollama" => "http://localhost:11434/v1", "other" => nil }.freeze
  # Gemini also lists models that do not answer text chats (images, music, speech…).
  NON_CHAT_MODELS = /embedding|imagen|image|tts|audio|veo|live|aqa|robotics|computer-use|customtools|deep-research|transcribe|banana/

  validates :provider, inclusion: { in: PROVIDERS.keys }
  validates :min_references, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 1000 }
  validates :daily_request_limit, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 10_000 }
  validate :validate_url

  # Before the migration, the forms show no AI instead of failing.
  def self.current
    table_exists? ? (first || new) : new
  end

  def base_url
    provider == "other" ? url.to_s.strip : PROVIDERS.fetch(provider, nil)
  end

  # The worker's MIRROR_AI_API_KEY, when set, replaces the stored key.
  def api_key
    return ENV["MIRROR_AI_API_KEY"] if ENV["MIRROR_AI_API_KEY"].present?
    return nil if encrypted_api_key.blank?
    raise RedmineMirror::Error, "Configure database_cipher_key in Redmine to use the stored AI key" unless Redmine::Ciphering.cipher_key
    Redmine::Ciphering.decrypt_text(encrypted_api_key)
  end

  def api_key=(value)
    if value.blank?
      self.encrypted_api_key = nil
    else
      raise RedmineMirror::Error, "Configure database_cipher_key in Redmine before saving an API key" unless Redmine::Ciphering.cipher_key
      self.encrypted_api_key = Redmine::Ciphering.encrypt_text(value)
    end
  end

  def api_key_set?
    ENV["MIRROR_AI_API_KEY"].present? || encrypted_api_key.present?
  end

  # A hosted API needs a key; a local one usually does not.
  def key_needed?
    provider == "gemini"
  end

  def usable?
    persisted? && enabled? && model.present? && base_url.present? && blocked_at.nil? && (api_key_set? || !key_needed?)
  end

  def client
    RedmineMirror::Ai::Client.new(url: base_url, model: model, api_key: api_key)
  end

  # Chat models from the last connection test, light ones first: a small model is
  # enough to match names.
  def models
    ids = JSON.parse(models_cache.presence || "[]")
    ids = ids.grep(/\Agemini-/).grep_v(NON_CHAT_MODELS) if provider == "gemini"
    ids.sort_by { |id| [self.class.light?(id) ? 0 : 1, id] }
  end

  # A segment of the name, so that "gemini" is not read as "mini": flash-lite, gpt-4o-mini,
  # llama3.1:8b…
  def self.light?(id)
    id.to_s.match?(/(?:\A|[-_.:])(?:lite|mini|small|nano|haiku|[1-8]b)(?:\z|[-_.:])/i)
  end

  # Lists the models, which also checks the key without spending credit, and lifts a block.
  def test_connection!
    ids = client.models
    update!(models_cache: JSON.generate(ids), verified_at: Time.current, blocked_at: nil, blocked_reason: nil)
    ids
  end

  def block!(reason)
    update_columns(blocked_at: Time.current, blocked_reason: reason.to_s.truncate(250))
  end

  def budget_left
    [daily_request_limit - MirrorAiUsage.requests_today, 0].max
  end

  def reserve_request!
    MirrorAiUsage.reserve!(daily_request_limit)
  end

  private

  def validate_url
    return if base_url.blank? && !enabled?
    RedmineMirror::Ai::Client.new(url: base_url)
  rescue RedmineMirror::Error => error
    errors.add(:url, error.message)
  end
end
