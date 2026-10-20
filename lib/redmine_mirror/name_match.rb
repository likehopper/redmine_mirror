# frozen_string_literal: true
# File: redmine_mirror/lib/redmine_mirror/name_match.rb
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
# Propose a local reference whose name is the source name, written differently.

module RedmineMirror
  module NameMatch
    module_function

    # Case, accents, punctuation and word order are ignored: "Dupont, Jérôme" reads
    # "dupont jerome" like "Jerome DUPONT".
    def key(name)
      name.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.scan(/[[:alnum:]]+/).sort.join(" ")
    end

    # The ID of the only candidate ([name, id] pairs, or their index) with the same key, else nil.
    def suggest(name, candidates)
      wanted = key(name)
      return nil if wanted.empty?
      matches = (candidates.is_a?(Hash) ? candidates : index(candidates)).fetch(wanted, [])
      matches.one? ? matches.first : nil
    end

    # Candidate IDs by key, to suggest for many names without normalizing the candidates
    # again for each one.
    def index(candidates)
      candidates.group_by { |label, _| key(label) }.transform_values { |pairs| pairs.map(&:last) }
    end

    # Similarity between 0 and 1 (Dice coefficient of the keys' trigrams), used to send the
    # AI only the closest local candidates of long lists.
    def score(left, right)
      a, b = trigrams(key(left)), trigrams(key(right))
      return 0.0 if a.empty? || b.empty?
      2.0 * (a & b).size / (a.size + b.size)
    end

    def trigrams(text)
      padded = "  #{text} "
      (0..padded.length - 3).map { |index| padded[index, 3] }.uniq
    end
  end
end
