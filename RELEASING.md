<!--
File: redmine_mirror/RELEASING.md

Redmine Mirror - modular project import and asynchronous replication.
SPDX-License-Identifier: GPL-2.0-or-later

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 2 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE for details.
-->

# Preparing a release

This document prepares publication; it does not automatically publish, push or deploy.
The current source is **1.0.0-beta.5**, a pre-release. The repository root must be
this plugin directory, with `init.rb` directly at its root.

## Before tagging

1. Confirm the intended release scope and review all changed files and tracked assets.
2. Run the standalone tests and the Docker CI runner; review the full GitHub results
   once a repository exists. For write behavior, run the relevant interinstance smoke tests.
3. Record exact tested versions/database engines in the compatibility matrix. Do not
   infer support from the minimum Redmine version declared in `init.rb`.
4. Run fresh install and uninstall/reinstall checks; test upgrade against a representative
   database backup when migrations change. Fresh installation does not prove upgrade behavior.
5. Verify artwork attribution and the license used to download it. Keep GPL and third-party
   notices distinct. Check the archive for secrets, local dumps, generated files and customer data.
6. Enable GitHub private vulnerability reporting and check the policy/contact links.
7. Choose a version in `lib/redmine_mirror.rb`, update the README badge/text and
   move the changelog entry from Unreleased into a dated release. Use a prerelease version
   when the plugin is still experimental.
8. Commit the reviewed tree. Confirm that no tracked changes remain.

## Candidate archive

From a Git checkout, build a local candidate for review:

```sh
bash scripts/package.sh HEAD
```

The script archives the committed revision, not working files. Outputs are
`dist/redmine_mirror-<version>.tar.gz` and its SHA-256 file. The archive contains
one top-level `redmine_mirror/` directory, including source, tests, docs and notices.
No repository is automatically created by this command.

## Tag and publish

After reviewing the exact commit and obtaining publication authorization:

```sh
git tag -a v<VERSION> -m "Redmine Mirror <VERSION>"
bash scripts/package.sh v<VERSION>
```

Replace `<VERSION>` with the reviewed version. The packaging script rejects a `v*`
tag that does not match the embedded version. Review the archive contents and install
that archive in a disposable Redmine. Push the reviewed commit/tag and create the
GitHub release, attaching the archive and SHA-256 file. Mark prereleases accordingly.
The CI creates candidate artifacts only; it never creates a public release.

Update the Redmine plugin directory description, version and compatibility selections
from the same release evidence. The directory is currently editable independently
from the code; resolve inconsistent stable-version claims before announcing a release.

## Reproducibility and rollback

The archive uses Git's committed tree and `gzip -n`; rebuilding the same revision
must produce the same checksum. Record the commit, tag, test evidence and artifact
hash. Keep annotated tag/history evidence. Runtime rollback after migrations requires
the matching database, attachment storage and plugin backup.
