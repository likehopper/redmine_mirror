/*
 * File: redmine_mirror/assets/javascripts/mirror.js
 *
 * Redmine Mirror - modular project import and asynchronous replication.
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 2 of the License, or (at your
 * option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE for details.
 *
 * Filter long mapping choice lists as the user types (jQuery UI ships with Redmine).
 */
$(function () {
  // Choices as [label, value, lowercase label], read once per list: a table's shared list
  // (data-choices) or the select's own options. The empty choice ("To configure") is not
  // suggested: clearing the field selects it.
  var lists = {};
  var choicesOf = function (select) {
    var shared = select.data("choices");
    if (shared) {
      if (!lists[shared]) {
        lists[shared] = $.map(JSON.parse($("#" + shared).text()), function (choice) {
          return [[choice[0], choice[1], choice[0].toLowerCase()]];
        });
      }
      return lists[shared];
    }
    return select.find("option").map(function () {
      return this.value ? [[$(this).text(), this.value, $(this).text().toLowerCase()]] : null;
    }).get();
  };
  // Long menus are slow to draw and to read: the first matches, then a narrower search.
  var LIMIT = 50;

  $("select.mirror-autocomplete").each(function () {
    var select = $(this);
    var minimum = parseInt(select.data("autocomplete-min"), 10) || 12;
    if (!select.data("choices") && select.find("option").length < minimum) return;
    var choices = null;
    var selectedText = function () {
      var option = select.find("option:selected");
      return option.length && option.val() ? option.text() : "";
    };
    // The select stays in the form and carries the submitted value.
    var input = $('<input type="text" class="mirror-autocomplete-input" autocomplete="off">')
      .attr("id", select.attr("id") + "-search")
      .attr("aria-label", $("label[for='" + select.attr("id") + "']").text())
      .attr("placeholder", select.data("placeholder"))
      .val(selectedText());
    select.hide().after(input);
    input.autocomplete({
      minLength: 0,
      delay: 100,
      source: function (request, response) {
        var term = request.term.toLowerCase();
        var matches = [];
        choices = choices || choicesOf(select);
        for (var i = 0; i < choices.length && matches.length <= LIMIT; i++) {
          if (choices[i][2].indexOf(term) >= 0) matches.push({ label: choices[i][0], value: choices[i][0], option: choices[i][1] });
        }
        if (matches.length > LIMIT) {
          matches.length = LIMIT;
          matches.push({ label: select.data("more") || "…", value: "", option: null, more: true });
        }
        response(matches);
      },
      focus: function (event, ui) {
        if (ui.item.more) event.preventDefault();
      },
      select: function (event, ui) {
        if (ui.item.more) return false;
        // A shared list's choice is added to the select when first picked.
        if (!select.find("option").filter(function () { return this.value === ui.item.option; }).length) {
          select.append($("<option>").val(ui.item.option).text(ui.item.label));
        }
        select.val(ui.item.option).trigger("change");
      },
      change: function (event, ui) {
        if (ui.item) return;
        // An emptied field leaves the reference unmapped; other free text that matches
        // no choice reverts to the current selection.
        if ($.trim(input.val()) === "") {
          select.val("").trigger("change");
        } else {
          input.val(selectedText());
        }
      }
    }).on("focus", function () {
      input.autocomplete("search", "");
    });
  });

  // The select stays enabled so that it is still submitted; the checkbox wins on save.
  var special = function (checkbox) {
    var cell = $(checkbox).closest("td").toggleClass("mirror-special-on", checkbox.checked);
    cell.find("select.mirror-autocomplete").attr("tabindex", checkbox.checked ? -1 : null);
    cell.find(".mirror-autocomplete-input").prop("disabled", checkbox.checked);
  };
  $("input.mirror-special-choice:checked").each(function () { special(this); });
  $(document).on("change", "input.mirror-special-choice", function () { special(this); });

  // Catalog refresh or execution in progress: reload while the Mirror content is visible,
  // unless a form field has been edited.
  var reload = $("[data-mirror-reload]:visible").first();
  if (reload.length) {
    var edited = false;
    $(document).on("input change", "form :input", function () { edited = true; });
    setTimeout(function () { if (!edited && reload.is(":visible")) window.location.reload(); },
      (parseInt(reload.data("mirror-reload"), 10) || 10) * 1000);
  }
});
