# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/text_format.rb
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
# Detect the markup of source texts and convert them to the destination's text format
# with Redmine's own formatters, so the result matches what the source displayed.

module RedmineMirror
  module TextFormat
    SOURCE_FORMATS = %w[auto textile markdown html].freeze
    # Texts without recognizable markup are read in the project's dominant format, else
    # as Textile, Redmine's historical default.
    FALLBACK = "textile"

    HTML = %r{\A\s*<(?:p|div|h[1-6]|ul|ol|table|blockquote|pre|span|strong|em|b|i|br|img|a)\b|</(?:p|div|li|td|th|h[1-6])>}i
    TEXTILE = [
      /^h[1-6][<>=()]*\.\s/, /^(?:bq|bc|pre|p|fn\d+)[<>=()]*\.\s/, /"[^"\n]+":(?:https?:|\/|#)/,
      /(?:^|\s)![^!\s][^!\n]*![:\s.,]?/, /^\|_\./, /(?:^|\s)@[^@\s][^@\n]*@(?=\s|$|[.,;:])/, /^\*{1,3}\s\S/, /^#+\s.*$\n^#+\s/
    ].freeze
    # Only constructs Textile lacks: "- item" lists, "> " quotes and **bold** are common
    # in Textile and plain text too, and must not tip a text towards Markdown.
    MARKDOWN = [
      /^\#{2,6}\s\S/, /`[^`\n]+`/, /^```/, /\[[^\]\n]+\]\([^)\s]+\)/, /!\[[^\]\n]*\]\([^)\s]+\)/,
      /^\|?\s*:?-{3,}:?\s*\|/, /~~[^~\n]+~~/
    ].freeze

    module_function

    # "textile", "markdown", "html", or nil when the text carries no recognizable markup.
    def detect(text)
      return nil if text.nil? || text.strip.empty?
      return "html" if text.match?(HTML)
      textile = TEXTILE.count { |pattern| text.match?(pattern) }
      markdown = MARKDOWN.count { |pattern| text.match?(pattern) }
      return nil if textile == markdown
      textile > markdown ? "textile" : "markdown"
    end

    # Name of the destination text formatting for a project: redmine_per_project_formatting
    # can override the global setting.
    def destination_format(project)
      (project.respond_to?(:text_formatting) && project.text_formatting.presence) || Setting.text_formatting.to_s
    end

    def family(name)
      case name.to_s
      when "textile" then "textile"
      when "markdown", "common_mark" then "markdown"
      when /\A(?:ckeditor|html)\z/i then "html"
      else "plain"
      end
    end

    # Run a block with the conversion settings of one synchronization.
    def with(settings)
      previous = Thread.current[:redmine_mirror_text_format]
      Thread.current[:redmine_mirror_text_format] = settings
      yield
    ensure
      Thread.current[:redmine_mirror_text_format] = previous
    end

    # Convert with the current settings; without settings, texts are copied unchanged.
    # Special cases of the text are noted for the execution log (see flags).
    def convert(text)
      settings = Thread.current[:redmine_mirror_text_format]
      return text unless settings && text.is_a?(String) && !text.strip.empty?
      note(*special_cases(text, settings["source_url"]))
      from = source_family(text, settings.fetch("source"), settings["fallback"])
      result = transform(text, source: settings.fetch("source"), target: settings.fetch("target"), fallback: settings["fallback"])
      note("converted:#{from}>#{family(settings.fetch('target'))}") unless result == text
      result
    end

    ISSUE_REFERENCE = /(?<![\w&\/])#\d+\b/
    IMAGE = /(?:^|\s)![^!\s][^!\n]*\.(?:png|jpe?g|gif|bmp|webp|svg)[^!\n]*!|!\[[^\]\n]*\]\(|<img\b/i
    ATTACHMENT_LINK = %r{/attachments/(?:download/|thumbnail/)?\d+|\battachment:}

    # What a reviewer should check in a converted text: references that keep source IDs,
    # links to the source server and images that live outside Redmine attachments.
    def special_cases(text, source_url)
      host = source_url.to_s.sub(%r{\Ahttps?://}, "").sub(%r{/+\z}, "")
      cases = []
      cases << "issue_references" if text.match?(ISSUE_REFERENCE)
      cases << "source_links" if (!host.empty? && text.include?(host)) || text.match?(%r{href="/(?:issues|projects|attachments|versions)/})
      cases << "images" if text.match?(IMAGE)
      cases << "rich_images" if text.include?("/system/rich/")
      cases << "attachment_links" if text.match?(ATTACHMENT_LINK)
      cases
    end

    # Special cases and warnings noted since the runner started the current record.
    def reset_flags
      Thread.current[:redmine_mirror_text_flags] = []
      Thread.current[:redmine_mirror_warnings] = []
    end

    # A problem that did not prevent the object from being synchronized, such as a
    # custom field value that could not be written. Grouped by message in the log.
    def warning(message)
      (Thread.current[:redmine_mirror_warnings] ||= []) << message.to_s
    end

    def warnings
      (Thread.current[:redmine_mirror_warnings] || []).uniq
    end

    def flags
      (Thread.current[:redmine_mirror_text_flags] || []).uniq
    end

    def note(*flags)
      (Thread.current[:redmine_mirror_text_flags] ||= []).concat(flags)
    end

    def source_family(text, source, fallback)
      source == "auto" ? (detect(text) || fallback || FALLBACK) : source
    end

    def transform(text, source:, target:, fallback: nil)
      raise Error, "Unknown source text format #{source}" unless SOURCE_FORMATS.include?(source)
      from = source_family(text, source, fallback)
      to = family(target)
      return text if from == to
      html = from == "html" ? text : Redmine::WikiFormatting.formatter_for(markup_formatter(from)).new(text).to_html
      to == "html" ? html : Redmine::WikiFormatting.html_parser_for(target).to_text(html)
    end

    # The most frequent markup detected in a source project, from its catalog counts. An
    # undetected text has no HTML tags, so it is read as Textile or Markdown, even in a
    # project mostly written with CKEditor.
    def dominant(counts)
      known = (counts || {}).slice("textile", "markdown").reject { |_, count| count.to_i.zero? }
      known.max_by { |_, count| count.to_i }&.first
    end

    # The registered formatter rendering a markup family on this Redmine.
    def markup_formatter(family)
      return "textile" if family == "textile"
      Redmine::WikiFormatting.format_names.include?("common_mark") ? "common_mark" : "markdown"
    end
  end
end
