#!/usr/bin/env bash
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/lib/prefilter.sh"
. "$ROOT/lib/log.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export JEV_GUARD_LOG="$tmp/sous/rep/jev-guard.jsonl"

log_decision "Bash" "git status" "jev" "allow" "allow" \
  '{"destructiveness":0.1}' "0.95" "118"

assert_eq "1" "$(wc -l < "$JEV_GUARD_LOG" | tr -d ' ')" "une ligne écrite"
assert_eq "0" "$(jq -e . "$JEV_GUARD_LOG" >/dev/null 2>&1; echo $?)" "JSON valide"
assert_eq "Bash"  "$(jq -r '.tool' "$JEV_GUARD_LOG")"    "champ tool"
assert_eq "allow" "$(jq -r '.verdict' "$JEV_GUARD_LOG")" "champ verdict"
assert_eq "true"  "$(jq -r '.agreed' "$JEV_GUARD_LOG")"  "accord calculé"
assert_eq "118"   "$(jq -r '.latency_ms' "$JEV_GUARD_LOG")" "latence"

# Le désaccord est calculé, pas fourni
log_decision "Bash" "rm -rf /tmp/x" "jev" "allow" "block" '{}' "0.5" "90"
assert_eq "false" "$(jq -r '.agreed' "$JEV_GUARD_LOG" | tail -1)" "désaccord détecté"

# Le journal ne doit JAMAIS contenir un secret en clair
log_decision "Bash" 'export K=sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA' \
  "prefilter" "block" "block" '{}' "1.0" "0"
derniere=$(tail -1 "$JEV_GUARD_LOG")
assert_eq "0" "$(grep -c 'sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA' <<<"$derniere")" \
  "aucun secret en clair dans le journal"
assert_eq "export K=[REDACTED]" "$(jq -r '.cmd_redacted' <<<"$derniere")" \
  "commande expurgée"

# Appel à 8 arguments produit cause égal à la chaîne vide
log_decision "Bash" "git log" "jev" "allow" "allow" '{}' "0.99" "50"
assert_eq "" "$(jq -r '.cause' "$JEV_GUARD_LOG" | tail -1)" "cause vide avec 8 arguments"

# Appel à 9 arguments produit cause égal à la valeur fournie
log_decision "Bash" "git diff" "jev" "allow" "allow" '{}' "0.99" "75" "timeout"
assert_eq "timeout" "$(jq -r '.cause' "$JEV_GUARD_LOG" | tail -1)" "cause fournie avec 9 arguments"

finish
