<!--
File: redmine_mirror/SECURITY.md

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

# Security policy

## Supported versions

Mirror is currently in beta (1.0.0-beta.17). Security fixes are considered for the
latest pre-release and, after 1.0.0, the latest maintained release.
No response or remediation deadline is promised.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/likehopper/redmine_mirror/security/advisories/new)
when enabled for the repository. If unavailable, arrange a private contact with the
maintainer through the [LikeHopper profile](https://github.com/likehopper) before
sending confidential details. Do not put an exploit, credential or private customer
data in a public issue. Maintainers should enable private reporting before publication.

Provide affected versions, configuration without secrets, reproduction steps, impact
and a minimal proof of concept using fictitious data. Relevant boundaries include
project permissions, private issue/history visibility, destination identifiers,
API credentials, download URLs, worker leases and conflict handling.

The maintainer and reporter will coordinate validation, fixes and disclosure.
