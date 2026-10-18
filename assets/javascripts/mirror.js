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
  $("select.mirror-autocomplete").each(function () {
    var select = $(this);
    var minimum = parseInt(select.data("autocomplete-min"), 10) || 12;
    if (select.find("option").length < minimum) return;
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
      delay: 0,
      source: function (request, response) {
        var term = request.term.toLowerCase();
        response(select.find("option").map(function () {
          var text = $(this).text();
          return text.toLowerCase().indexOf(term) >= 0 ? { label: text, value: text, option: this.value } : null;
        }).get());
      },
      select: function (event, ui) {
        select.val(ui.item.option).trigger("change");
      },
      change: function (event, ui) {
        // Free text that matches no choice reverts to the current selection.
        if (!ui.item) input.val(selectedText());
      }
    }).on("focus", function () {
      input.autocomplete("search", "");
    });
  });

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
