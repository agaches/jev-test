#!/usr/bin/env bash
# Corpus d'acceptation (spec §12) : vérifie de bout en bout, contre le hook
# réel et des réponses Jev figées, que les faux positifs connus (SHA git,
# nom de paramètre d'URL) passent bien en `allow` et que les commandes
# destructrices construites dynamiquement sont bien rattrapées.
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export JEV_GUARD_LOG="$tmp/j.jsonl"
export TYPESAFE_API_KEY=cle-de-test
export JEV_GUARD_CURL="$ROOT/tests/stubs/curl-fixture"
export JEV_GUARD_MODE=active
export CLAUDE_PROJECT_DIR=/projet

cas=0
while IFS=$'\t' read -r commande fixture attendu; do
  [ -n "$commande" ] || continue
  export JEV_FIXTURE_REPONSE="$ROOT/tests/fixtures/reponses/$fixture.json"
  export JEV_GUARD_CACHE_DIR="$tmp/c-$RANDOM"   # cache neuf par cas

  entree=$(jq -nc --arg c "$commande" '{tool_name:"Bash",tool_input:{command:$c}}')
  sortie=$(printf '%s' "$entree" | bash "$ROOT/hooks/jev-guard.sh" 2>/dev/null)
  rc=$?

  case $rc in
    2) obtenu=block ;;
    0) if grep -q '"permissionDecision"' <<<"$sortie"; then obtenu=ask; else obtenu=allow; fi ;;
    *) obtenu="rc=$rc" ;;
  esac

  assert_eq "$attendu" "$obtenu" "${commande:0:50}"
  cas=$((cas + 1))
done < "$ROOT/tests/fixtures/commands.tsv"

# Preuve que le corpus a réellement tourné : sans cette assertion, un TSV
# absent, vide ou mal séparé fait itérer la boucle zéro fois et `finish`
# rapporte un succès n'ayant rien vérifié.
assert_eq "14" "$cas" "les 14 cas du corpus ont été exécutés"

finish
