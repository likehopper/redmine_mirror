# File: redmine_mirror/test/environment/formats/Dockerfile
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
# Source Redmine 4.2 with CKEditor (HTML, Rich images) and per-project text formatting,
# for the text format conversion checks. Plugin revisions are pinned.

FROM redmine:4.2
# The official image already ships git and ImageMagick (needed by Rich thumbnails);
# mimemagic, a Paperclip dependency, needs the freedesktop MIME database.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends shared-mime-info \
 && rm -rf /var/lib/apt/lists/*
# The CKEditor submodule still points to git://, which GitHub no longer serves.
RUN git config --global url."https://github.com/".insteadOf git://github.com/ \
 && git clone --quiet --recursive --branch 1.2.3 --depth 1 https://github.com/a-ono/redmine_ckeditor.git /opt/plugins/redmine_ckeditor \
 && git clone --quiet https://github.com/a-ono/redmine_per_project_formatting.git /opt/plugins/redmine_per_project_formatting \
 && git -C /opt/plugins/redmine_per_project_formatting checkout --quiet c33cca199b7ff0db54b1bbebd8cb5c83bb7dcd58 \
 && cp -a /opt/plugins/. plugins/ \
 && printf 'production:\n  adapter: sqlite3\n  database: /tmp/build.sqlite3\n' > config/database.yml \
 && bundle install --quiet
