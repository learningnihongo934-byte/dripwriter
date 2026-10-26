#!/usr/bin/env bash
# Wraps web/index.html in a full HTML document at docs/app/index.html (served by GitHub Pages).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs/app
{ echo '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><link rel="icon" href="../icon.png"></head><body>'; cat web/index.html; echo '</body></html>'; } > docs/app/index.html
cp assets/icon.png docs/icon.png
echo "Built docs/app/index.html"
