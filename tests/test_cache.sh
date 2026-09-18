#!/usr/bin/env bash
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/lib/prefilter.sh"
. "$ROOT/lib/log.sh"
. "$ROOT/lib/cache.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export JEV_GUARD_CACHE_DIR="$tmp/cache"

cle=$(cache_key "Bash" "git status" "/projet")
assert_eq "64" "${#cle}" "clé sha256 de 64 caractères"

cle2=$(cache_key "Bash" "git status" "/autre")
assert_eq "0" "$([ "$cle" != "$cle2" ]; echo $?)" "le cwd change la clé"

cache_get "$cle" >/dev/null
assert_rc 1 $? "miss sur cache vide"

cache_put "$cle" "allow" '{"destructiveness":0.1}'
assert_eq "allow" "$(cache_get "$cle")" "hit après écriture"

# Entrée expirée : ts_epoch il y a 8 jours
vieux=$(cache_key "Bash" "vieille commande" "/projet")
mkdir -p "$JEV_GUARD_CACHE_DIR"
jq -nc --argjson ts "$(( $(date +%s) - 8*24*3600 ))" \
  '{verdict:"allow",scores:{},ts_epoch:$ts}' \
  > "$JEV_GUARD_CACHE_DIR/$vieux.json"
cache_get "$vieux" >/dev/null
assert_rc 1 $? "miss sur entrée expirée"
assert_eq "0" "$([ ! -f "$JEV_GUARD_CACHE_DIR/$vieux.json" ]; echo $?)" \
  "entrée expirée supprimée"

# Aucune commande en clair dans le cache
assert_eq "0" "$(grep -rl 'git status' "$JEV_GUARD_CACHE_DIR" 2>/dev/null | wc -l | tr -d ' ')" \
  "aucune commande en clair dans le cache"

finish
