<!--
File: redmine_mirror/test/environment/VALIDATION.md

Redmine Mirror - modular project import and asynchronous replication.
SPDX-License-Identifier: GPL-2.0-or-later

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 2 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE for details.

Document Mirror setup, operation, extension points or validation evidence.
-->

# Validation record

Every entry below was validated on **Redmine 6.1.4 with SQLite** only, in the
[two-instance environment](README.md) or the [CI runner](../compatibility/README.md).
PostgreSQL, MariaDB, MySQL and other Redmine versions are not validated. Temporary
projects created by smoke checks were deleted afterwards.

## Current state (October 15, 2026)

CI runner (`redmine:6.1.4`, Ruby 3.4.11, Rails 7.2.3.2, SQLite, Chromium):

| Suite | Result |
| --- | --- |
| Redmine functional and system tests | 73 tests, 312 assertions, no failure |
| Standalone engine | 25 tests, 88 assertions |
| HTTP client | 4 tests, 12 assertions |
| Adapter example | 5 tests, 18 assertions |

Fresh install and uninstall/reinstall of the eight migrations succeed. The GitHub
workflow is ready but has not run on GitHub yet.

Documentation walkthrough (`test/documentation/run.sh`): a seeded source Redmine and the
destination in one container; 14 steps, 85 assertions, no failure. It covers connection,
mappings, preview, import of 12 issues with history, attachments and relations, schedule,
history and a conflict kept locally. No external adapter (SLA, Reporting)
is validated.

## History

### October 7, 2026 — first two-instance validation

- Both instances migrate and serve `/login`.
- Permissions: administrator, authorized member, member without permission, module
  disabled, anonymous visit of a private project, access to another project.
- Real API import: preview without writes, 12 issues, 13 time entries, 25 persisted
  correspondences, unchanged rerun, local change detected.
- 38 Redmine tests / 134 assertions; engine 14 / 50.

### Project configuration and synchronization

- Connection with encrypted key, Issues/Time tracking tabs, persisted mappings,
  anonymized users, account for anonymized time, foreign references and forbidden writes
  rejected. Chromium: connection, save and reference refresh from the APIs.
- *Users* extracted as a module: dedicated tab, automatic dependencies, centralized
  anonymization, older configurations still read.
- Preview/import buttons, per-project frequency, persistent queue, database lease, logs,
  error without key leak, cancelled automatic runs. With the separate worker: preview
  without writes, import of 12 issues and 13 time entries, automatic run on a simulated
  deadline, rerun without duplicates, next deadline set.
- History filters (status, mode, origin, module, dates, pagination) and log filters
  (module, action, source ID). Progress counts processed objects: 25/25, 100%.
- Logs with persisted remote/local IDs and links; object mappings tab scoped to the
  project: 25 correspondences, 12 remote and 12 local issue links.

### History and attachments

- 36 journals (12 private) with their dates, 12 files with verified content, unchanged
  rerun, local journal change refused. Source administrator anonymized as configured.
- Persistent run on the manual project: public and private notes, status change and
  `mirror-note.txt` visible on the local issue.

### October 9, 2026 — privacy, metadata, relations and references

- 6 private and 6 public issues with fixed dates: dates and authors match the source API,
  privacy kept, private issues hidden from a reader without permission. Invalid dates,
  unmapped author and non-local destination rejected before writes. Engine 18 / 66.
- Relations across a main project, two subprojects and an independent project, including
  *precedes* with a 2-day delay: ignore/log, private notes without duplicates, late target
  import, reuse from both ends, delays kept, native cross-project setting enforced, local
  change detected, ambiguous configurations rejected. 39 tests / 137 assertions.
- Pending relations (migration 006): `pending` kept, `blocked` recorded in preflight,
  resolved relations removed; filter, links, counter and project isolation tested.
- Categories and versions: creation, assignee, due date, status, sharing and issue
  references on four projects; historical changes translated; local change rejected.
  40 tests / 144 assertions; engine 23 / 79.
- Clickable IDs for relations, journals, categories, versions and mapping tables;
  **Mirror source issue** link on local issues, for users with *Configure Mirror mappings*.
  Two-level navigation separating synchronization from modules: 41 tests / 155 assertions.

### Hierarchy, watchers and custom fields

- Hierarchy and watchers: missing then resolved parent, idempotence, local conflict,
  cycle, cross-project rules, anonymization, watcher without visibility refused, local
  subscriptions kept, removals not propagated. Smoke on four projects with an
  out-of-project watcher. 50 tests / 197 assertions.
- Custom fields: per-project tables, field then value forms, bracketed values,
  incompatible formats, out-of-project fields, missing or invalid values, local values
  kept, dates, order-independent fingerprints, enumerations. Smoke with seven formats and
  a required field without local default. 61 tests / 234 assertions.
- **Ignore this field**: per-project persistence, refused for users, values and history
  details excluded, private notes kept. 63 tests / 250 assertions.

### Conflicts, pending parents and navigation

- Conflicts (migration 007): keep local, recheck, fingerprints kept, user without
  permission, foreign ID and resolution during a queued run refused. Smoke: detection,
  single persistent conflict, logged exclusion, recheck without bypass, resolution after
  correction. 68 tests / 272 assertions.
- Pending parents (migration 008): pagination, filter, links, counter, isolation; cycle
  refused, nothing persisted by a preview, blocked row in preflight, removed after a
  successful run. 70 tests / 288 assertions.
- Wrapping tabs: in French at 800, 1280 and 1920 pixels, every module link stays in its
  container. 71 tests / 297 assertions.

### Code conventions and publication

- 104 commentable text files carry a full path and GPL-2.0-or-later header; exceptions
  listed in [FILE_HEADERS.md](../../doc/FILE_HEADERS.md). Syntax, Markdown links, YAML
  content, ERB output and asset bytes checked.
- Adapter tutorial and example: 5 tests / 18 assertions; no real endpoint added.
- Standalone CI runner from `redmine:6.1.4`: 71 tests / 300 assertions. Packaging tested
  in a throwaway Git repository: installable root folder, private hidden files excluded,
  SHA-256, reproducible rebuild, mismatching tag refused. Version kept at `0.1.0-dev`.
- October 15, 2026 — adapter API version 1: `RedmineMirror.register_adapter`, validated
  keys, declared phases, availability, adapter-provided links and partial; a module whose
  plugin disappeared blocks runs. Current state above.

Adaptateurs Reporting entre deux instances (16 octobre 2026) : redmine_reporting
(branche `feat/rest-api`) monté sur la source, la destination et le worker par
`compose.reporting.yml`. Le démarrage en production a révélé que Mirror ne
démarrait plus : Zeitwerk attendait `RedmineMirror::Version` dans `version.rb`. Un
premier correctif définissant ce module masquait le modèle `Version` de Redmine et
faisait échouer six smokes ; la version est désormais déclarée dans
`lib/redmine_mirror.rb` et `version.rb` est supprimé. `zeitwerk:check` réussit avec
les deux plugins et s'exécute dans le runner CI ; un test vérifie que l'espace de
noms ne masque pas les modèles Redmine. `reporting_smoke.sh` réussi :
sous-projet hérité non copié, modules et correspondances des trackers dans Chromium,
aperçu sans écriture, import par le worker (réglages et deux politiques avec leurs
recharges), liens source/local, relance inchangée, mise à jour après modification de
la source, modification locale signalée en conflit puis conservée par l'interface.
Projet temporaire supprimé, données source restaurées. Redmine 6.1.4 / SQLite.

Candidat 1.0.0-beta.1 (16 octobre 2026), environnement à deux instances en production
avec Reporting monté : `smoke.rb`, `synchronization_smoke.rb`, `history_smoke.rb`,
`relations_smoke.rb`, `issue_state_smoke.rb`, `custom_fields_smoke.rb`,
`conflicts_smoke.rb`, `relations_ui_smoke.rb` et `reporting_smoke.sh` réussis ; suites
Redmine de l'environnement : 74 tests / 315 assertions, aucun échec.
`synchronization_smoke.rb` utilise désormais une sélection fixe de modules (27 objets)
au lieu de celle du projet manuel, et attend la connexion et l'enregistrement de la
planification avant de vérifier : deux exécutions consécutives réussies.

Versions croisées (16 octobre 2026), `versions.sh`, piles jetables, SQLite, production :
source Redmine 4.2.10 (Ruby 2.7.8) → destination 6.1.4, source 5.0.12 (Ruby 3.1.7) →
destination 6.1.4, source 4.2.10 → destination 5.1.13 (Ruby 3.2.11). Pour chaque paire,
configuration par l'interface (correspondances par nom, administrateur source anonymisé)
puis `smoke.rb`, `synchronization_smoke.rb`, `history_smoke.rb`, `relations_smoke.rb`,
`issue_state_smoke.rb`, `custom_fields_smoke.rb` et `conflicts_smoke.rb` réussis.
Sur la destination 5.1 (Rails 6.1), SQLite renvoyait « database is locked » entre le
worker et le serveur web, y compris pour les mails de Redmine : l'environnement déclare
désormais `timeout: 5000`, comme le `database.yml` d'exemple de Redmine.

Saisie du projet source par identifiant, références limitées à celles utilisées et
listes filtrables (17 octobre 2026) : runner CI 80 tests Redmine / 339 assertions,
`zeitwerk:check`, moteur 26 / 89. `versions.sh` réussi pour source 5.0.12 →
destination 5.1.13 et source 4.2.10 → destination 6.1.4 (sept smokes d'écriture).

Compte source non administrateur (17 octobre 2026), `MIRROR_SOURCE_ACCOUNT=reader`
(`reader_account.rb` : rôle en lecture seule sur tous les projets source), source 4.2.10
→ destination 6.1.4 : six smokes d'écriture réussis. Les catégories, dont la liste exige
« Gérer les catégories », sont reprises des demandes, sans assigné par défaut ;
`custom_fields_smoke` est sauté, Redmine réservant les définitions de champs aux
administrateurs. L'environnement exécute désormais les tâches de mail en ligne pour
éviter les verrous SQLite pendant l'initialisation, et attend jusqu'à 5 minutes une
source neuve.

1.0.0-beta.6 (17 octobre 2026) : aperçu qui liste toutes les erreurs, réglage « Quand un
objet échoue » (ignorer par défaut, statut « Terminée avec erreurs »), journal avec bilan,
erreurs par cause et cas particuliers à vérifier, chargement unique d'un plugin installé
par lien symbolique. Runner CI (installation par lien symbolique) : 98 tests Redmine /
420 assertions. `versions.sh` source 4.2 → destination 6.1.4 : sept smokes réussis.
`formats.sh` source 4.2 → destination 5.1.13 CKEditor : conversion et marqueurs du journal
vérifiés. Mise en évidence sur la préproduction : source Redmine (projet
`vygon-tma-sites-internet`) → Redmine 5.1.13, 395 demandes et 744 saisies importées après
la correction des catégories d'un autre projet (beta.5).

1.0.0-beta.7 (17 octobre 2026) : sur la préproduction, enregistrer la connexion avec tous
les modules lisait la source dans la requête web pendant plusieurs minutes (502 du proxy,
threads Puma occupés). Le worker actualise désormais les références (migration 012), avec
l'étape, le module et le nombre d'éléments lus, et chaque demande source n'est lue qu'une
fois pour tous les modules. Runner CI : 99 tests Redmine / 426 assertions. `versions.sh`
source 4.2 → destination 6.1.4 : `ui_smoke.rb` (attente du worker) et sept smokes réussis.

1.0.0-beta.8 (17 octobre 2026), d'après les erreurs de la préproduction : filtre du journal
par cause, nom et lien de correction des correspondances manquantes, détails d'historique
non traduisibles ignorés sans perdre le journal, limite des pièces jointes alignée sur la
destination, worker explicite sur les migrations en attente. Runner CI : 100 tests
Redmine / 435 assertions. `versions.sh` source 4.2 → destination 6.1.4 : sept smokes réussis.

1.0.0-beta.9 (18 octobre 2026) : sur la préproduction, un champ « Impact level » activé
pour tous les projets mais pour le seul tracker « Risk » bloquait 1139 objets. Une valeur
de champ impossible à écrire est désormais ignorée avec un avertissement groupé par cause ;
la demande, son temps passé et son historique sont importés. Runner CI : 101 tests Redmine
/ 447 assertions. `versions.sh` source 4.2 → destination 6.1.4 : sept smokes réussis.
L'environnement de test désactive les notifications, cause des verrous SQLite au démarrage
de la source Redmine 4.2.

1.0.0-beta.10 (18 octobre 2026) : sur la préproduction, des conflits « Local modification
detected for issue_watchers » apparaissaient sans intervention : Redmine abonne l'auteur et
le compte API qui écrit les demandes. Seuls les observateurs ajoutés par Mirror sont
désormais surveillés. Runner CI : 102 tests Redmine / 449 assertions. `versions.sh` source
4.2 → destination 6.1.4 : sept smokes réussis.

1.0.0-beta.11 (18 octobre 2026) : sur la préproduction, une référence `#1231043` dans une
description restait le numéro de la source. Les références de demandes (`#N`, `##N`,
`###N`, liens `<source>/issues/N`) pointent vers la demande importée ; une demande non
importée devient un lien vers la source, et une demande importée plus loin dans la même
exécution est corrigée par une seconde passe. Runner CI : 103 tests Redmine / 451
assertions. `versions.sh` source 4.2 → destination 6.1.4 : sept smokes réussis.
`formats.sh` source 4.2 CKEditor → destination 5.1.13 CKEditor : réussi, relance inchangée.

1.0.0-beta.12 (18 octobre 2026) : la configuration passe dans l'onglet Mirror des
paramètres du projet et le menu Mirror devient la page d'exploitation (vue d'ensemble avec
mise en route, historique, conflits, liens en attente, correspondances d'objets). Trois
permissions (voir, lancer, configurer) et liste des Redmine source autorisés dans la
configuration du plugin. Runner CI : 116 tests Redmine / 523 assertions. `versions.sh`
source 4.2 → destination 6.1.4 : test d'interface et sept smokes réussis. `formats.sh`
source 4.2 CKEditor → destination 5.1.13 CKEditor : réussi. Captures du guide régénérées
par `test/documentation/run.sh`.
