# File: redmine_mirror/test/environment/formats/destination.Dockerfile
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
#
# Destination with Mirror's test base and a CKEditor plugin supplied at build time
# (compose.formats.yml, MIRROR_CKEDITOR_PATH). The plugin is not part of this repository.

ARG BASE_IMAGE=redmine-mirror-test:6.1.4
FROM ${BASE_IMAGE}
COPY --from=ckeditor . plugins/redmine_ckeditor
RUN rm -rf plugins/redmine_ckeditor/.git && bundle install --quiet
