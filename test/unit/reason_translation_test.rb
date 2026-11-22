# frozen_string_literal: true
# File: redmine_mirror/test/unit/reason_translation_test.rb
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
# Verify that run reasons recorded in English are shown in the user's language.

require_relative "../test_helper"

class MirrorReasonTranslationTest < ActionView::TestCase
  include MirrorHelper

  def teardown
    ::I18n.locale = :en
  end

  def test_known_reasons_are_translated_and_nested_parts_too
    ::I18n.locale = :fr
    assert_equal "770 objet(s) non synchronisé(s) ; premier : Correspondance manquante (Rôles) pour la référence source #26",
      mirror_reason_text("770 object(s) not synchronized; first: Missing role mapping for source ID 26")
    assert_equal "Le champ source #78 et le champ local \"Defect Cause\" n'ont pas le même format ou la même multiplicité ; la valeur n'a pas été importée",
      mirror_reason_text("Source custom field #78 and destination field \"Defect Cause\" have incompatible formats or multiplicity; the value was not imported")
    # The remote Redmine's own message is kept as written.
    assert_equal "L'API Redmine a répondu HTTP 422 à POST time_entries.json: User is invalid",
      mirror_reason_text("Redmine API returned HTTP 422 for POST time_entries.json: User is invalid")
    assert_equal "Modification locale détectée (Demandes, objet source #1295)",
      mirror_reason_text("Local modification detected for issue_tracking source ID 1295")
  end

  def test_unknown_reasons_stay_as_recorded_and_translations_keep_the_original_on_hover
    ::I18n.locale = :fr
    assert_equal "Something new happened", mirror_reason_label("Something new happened")
    label = CGI.unescapeHTML(mirror_reason_label("Mapped watcher cannot view destination issue"))
    assert_includes label, "L'observateur associé ne peut pas voir la demande locale"
    assert_includes label, 'title="Mapped watcher cannot view destination issue"'
  end

  # English pages show the recorded text unchanged, as before translation existed.
  def test_english_reproduces_every_recorded_form
    [
      "3 object(s) not synchronized; first: Missing tracker mapping for source ID 17",
      "Custom field \"Prioritization %\" is not enabled for destination tracker \"Support\": enable it, or ignore source field #82; the value was not imported",
      "Source custom field #78 and destination field \"Defect Cause\" have incompatible formats or multiplicity; the history change was not imported",
      "Redmine API returned HTTP 404 for GET attachments/download/…",
      "Redmine API returned HTTP 403 for GET issues.json (Mirror source: client_locked)",
      "Local modification detected for issue_tracking source ID 1295",
      "Local modification detected for relations source ID 4: the destination relation was deleted",
      "Mapped watcher cannot view destination issue",
      "The destination custom field mapped to source field #5 is not enabled in this project",
      "Missing value mapping for custom field source ID 901",
      "Enable the Wiki module on the destination project",
      "Missing owning issue correspondence",
      "Issue has no synchronized destination",
      "Parent wiki page \"Start\" is not imported"
    ].each { |reason| assert_equal reason, mirror_reason_text(reason) }
  end

  def test_every_form_has_both_translations
    keys = MIRROR_REASON_FORMS.map(&:last)
    %i[en fr].each do |locale|
      keys.each { |key| assert ::I18n.exists?(key, locale), "#{key} is missing in #{locale}" }
    end
  end
end
