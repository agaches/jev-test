#!/usr/bin/env bash
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/lib/fallback.sh"

# --- Comportements à préserver ---
assert_eq block "$(fallback_verdict Bash 'rm -rf /')"              "rm -rf /"
assert_eq block "$(fallback_verdict Bash 'dd if=/dev/zero of=/dev/sda')" "dd"
assert_eq block "$(fallback_verdict Bash 'npm publish')"           "npm publish"
assert_eq block "$(fallback_verdict Bash 'git push --force origin main')" "force push main"
assert_eq block "$(fallback_verdict Bash 'export password=hunter2')" "motif password="
assert_eq block "$(fallback_verdict Write '/projet/.env')"          "fichier .env"
assert_eq block "$(fallback_verdict Edit '/projet/id_rsa')"         "clé privée"
assert_eq allow "$(fallback_verdict Bash 'ls -la')"                 "commande anodine"
assert_eq ask   "$(fallback_verdict Bash 'rm -r build/')"           "suppression récursive"

# --- Faux positifs CONSERVÉS volontairement (spec §9) ---
# Le repli reproduit le comportement actuel, défauts compris. C'est un
# plancher assumé, pas une régression. Ne pas « corriger » ces cas ici :
# c'est Jev qui les traite en mode nominal.
assert_eq block "$(fallback_verdict Bash 'git show a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0')" \
  "faux positif SHA git conservé en mode dégradé"
assert_eq block "$(fallback_verdict Bash 'curl "https://ex.com/d?token=public"')" \
  "faux positif token= conservé en mode dégradé"

finish
