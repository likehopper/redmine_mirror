#!/usr/bin/env bash
# File: redmine_mirror/test/environment/preprod/assets.sh
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
# Generate the demo files the source scripts attach (images, PDFs, office files),
# instead of keeping binaries in the repository. Needs ImageMagick 7, LibreOffice and zip.
# Usage: bash assets.sh [output directory, default /tmp/mirror-demo-assets]

set -euo pipefail
out=${1:-/tmp/mirror-demo-assets}
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
font=DejaVu-Sans

magick -size 900x500 xc:'#f4f6fb' -font $font -fill '#1f3a93' -pointsize 34 -annotate +40+60 'Architecture de la plateforme' \
  -fill none -stroke '#1f3a93' -strokewidth 3 -draw 'rectangle 60,120 300,260' -draw 'rectangle 340,120 580,260' \
  -draw 'rectangle 620,120 860,260' -draw 'line 300,190 340,190' -draw 'line 580,190 620,190' \
  -stroke none -fill '#333' -pointsize 22 -annotate +110+200 'Front' -annotate +400+200 'API' -annotate +680+200 'Base' \
  -pointsize 16 -annotate +40+460 'Schéma de démonstration — données fictives' "$out/schema-architecture.png"
magick -size 1280x720 gradient:'#88c':'#ecc' -font $font -fill white -pointsize 48 -annotate +60+380 "Capture d'écran (démo)" "$out/capture-ecran.jpg"
magick -size 1280x720 gradient:'#c88':'#eec' -font $font -fill white -pointsize 48 -annotate +60+380 "Capture v2 : même nom de fichier" "$out/capture-ecran-v2.jpg"
magick -size 200x60 xc:white -font $font -pointsize 28 -fill red -annotate +20+40 'Étape 1' \
  \( -size 200x60 xc:white -font $font -pointsize 28 -fill green -annotate +20+40 'Étape 2' \) \
  \( -size 200x60 xc:white -font $font -pointsize 28 -fill blue -annotate +20+40 'Étape 3' \) \
  -set delay 80 -loop 0 "$out/animation-etapes.gif"
magick -size 64x64 xc:none -fill '#e67e22' -draw 'circle 32,32 32,4' "$out/LOGO-MAJUSCULES.PNG"
cat > "$out/logo-vectoriel.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60"><rect width="120" height="60" rx="8" fill="#1f3a93"/><text x="60" y="38" font-family="sans-serif" font-size="20" fill="#fff" text-anchor="middle">Démo</text></svg>
SVG
# About 1.2 MB: a heavy attachment.
magick -size 1600x1200 plasma:fractal -quality 95 "$out/photo-lourde.jpg"
for page in 1 2 3; do
  magick -size 1240x1754 xc:white -font $font -fill black -pointsize 36 -annotate +100+200 "Spécification fonctionnelle — page $page/3" \
    -pointsize 24 -annotate +100+300 "Données fictives de démonstration" "$work/p$page.png"
done
magick "$work/p1.png" "$work/p2.png" "$work/p3.png" -units PixelsPerInch -density 150 "$out/specification-fonctionnelle.pdf"
# Spaces and parentheses in the file name.
magick -size 1240x1754 xc:white -font $font -fill black -pointsize 36 -annotate +100+200 'Devis n° 2026-042 (démo)' \
  -pointsize 24 -annotate +100+300 'Total HT : 12 500,00 €' -units PixelsPerInch -density 150 "$out/Devis client (v2) 2026.pdf"
printf 'cas;résultat attendu;statut\nconnexion;OK;passé\nexport PDF;fichier généré;échoué\n' > "$out/recette.csv"
printf 'Compte rendu de réunion (démo)\n\nPrésents : client, équipe projet.\nDécision : lot 1 en recette le 15/12.\n' > "$work/compte-rendu.txt"
libreoffice --headless --convert-to xlsx --outdir "$work" "$out/recette.csv" > /dev/null
libreoffice --headless --convert-to docx --outdir "$work" "$work/compte-rendu.txt" > /dev/null
mv "$work/recette.xlsx" "$out/recette.xlsx"
mv "$work/compte-rendu.docx" "$out/compte-rendu réunion.docx"
printf '{\n  "client": "démo",\n  "lots": [1, 2]\n}\n' > "$out/config-exemple.json"
(cd "$out" && zip -q -j livrables-lot1.zip recette.csv config-exemple.json)
ls -1 "$out"
