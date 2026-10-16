# File: redmine_mirror/test/compatibility/Dockerfile
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

FROM redmine:6.1.4
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends chromium chromium-driver build-essential libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*
ENV BUNDLE_WITHOUT=development
RUN bundle config set without development
