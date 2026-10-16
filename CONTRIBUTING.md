<!--
File: redmine_mirror/CONTRIBUTING.md

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

# Contributing

Use the [issue tracker](https://github.com/likehopper/redmine_mirror/issues) for bugs
and feature requests. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

For bugs, include the plugin commit/version, Redmine/Ruby/Rails/database versions,
enabled adapters, mapping configuration without credentials, expected and actual
behavior, and a minimal reproduction. Remove API keys, private notes, attachments
and personal/customer data from logs and screenshots.

## Development

Work on a branch and keep changes focused. Follow [development conventions](doc/DEVELOPMENT.md).
English identifiers/comments and GPL/SPDX path headers are required for plugin-owned
commentable files. Preserve third-party notices. Use native Redmine authorization
and validate every submitted ID within the current project.

To add a module, follow [the adapter tutorial](doc/ADAPTERS.md). Test preview,
first import, repeated import, source updates, local conflicts and project isolation.
Do not create administration-owned definitions through project manager permissions.

Run standalone tests from the plugin root:

```sh
ruby test/core_test.rb
ruby test/client_test.rb
ruby test/adapter_example_test.rb
```

Then run the [Docker CI runner](test/compatibility/README.md). Changes involving
remote reads/writes also require the relevant real two-instance smoke tests in the
[development environment](test/environment/README.md). Keep demo and production data separate.

Describe the problem, resulting behavior and meaningful validation in each PR.
Update the changelog and relevant guides when behavior or the adapter contract changes.
Follow the [code of conduct](CODE_OF_CONDUCT.md).
