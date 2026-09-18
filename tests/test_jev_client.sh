#!/usr/bin/env bash
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/lib/jev-client.sh"

export TYPESAFE_API_KEY=cle-de-test

# --- Construction du payload ---
p=$(jev_build_bash_payload 'git status' '/projet' true)
assert_eq "0" "$(jq -e . <<<"$p" >/dev/null 2>&1; echo $?)" "payload JSON valide"
assert_eq "jev-latest" "$(jq -r '.model' <<<"$p")"              "modèle par défaut"
assert_eq "git status" "$(jq -r '.state.command' <<<"$p")"      "commande dans l'état"
assert_eq "/projet"    "$(jq -r '.state.cwd' <<<"$p")"          "cwd dans l'état"
assert_eq "Bash"       "$(jq -r '.state.tool' <<<"$p")"         "outil dans l'état"
assert_eq "3" "$(jq -r '.questions | length' <<<"$p")"          "trois questions"
assert_eq "score"  "$(jq -r '.questions.destructiveness.type' <<<"$p")" "type score"
assert_eq "noul"   "$(jq -r '.questions.secret_exposure.type' <<<"$p")" "type noul"
assert_eq "choice" "$(jq -r '.questions.blast_radius.type' <<<"$p")"    "type choice"
assert_eq "4" "$(jq -r '.questions.destructiveness.criteria | length' <<<"$p")" \
  "rubrique à quatre niveaux"

pm=$(JEV_GUARD_MODEL=jev-1.13.0 jev_build_bash_payload 'ls' '/p' false)
assert_eq "jev-1.13.0" "$(jq -r '.model' <<<"$pm")" "modèle surchargeable"

pf=$(jev_build_file_payload '/projet/.env.staging' Write)
assert_eq "1" "$(jq -r '.questions | length' <<<"$pf")" "une seule question fichier"
assert_eq "noul" "$(jq -r '.questions.sensitive_file.type' <<<"$pf")" "type noul fichier"

# --- Transport ---
r=$(JEV_GUARD_CURL="$ROOT/tests/stubs/curl-ok" jev_query "$p")
rc=$?
assert_rc 0 "$rc" "réponse 200 acceptée"
assert_eq "0.02" "$(jq -r '.answers.secret_exposure.noul' <<<"$r")" "réponse parsable"

# Modes de défaillance exigés par la spec §12 (Ruling 3 / Ruling 5)
JEV_GUARD_CURL="$ROOT/tests/stubs/curl-badjson" jev_query "$p" >/dev/null 2>&1
rc=$?
assert_rc 1 "$rc" "JSON malformé rejeté"
assert_eq "json_invalide" "$JEV_LAST_ERROR" "cause JSON malformé"

JEV_GUARD_CURL="$ROOT/tests/stubs/curl-429" jev_query "$p" >/dev/null 2>&1
rc=$?
assert_rc 1 "$rc" "quota dépassé rejeté"
assert_eq "http_429" "$JEV_LAST_ERROR" "cause quota dépassé"

JEV_GUARD_CURL="$ROOT/tests/stubs/curl-500" jev_query "$p" >/dev/null 2>&1
rc=$?
assert_rc 1 "$rc" "HTTP 500 rejeté"
assert_eq "http_500" "$JEV_LAST_ERROR" "cause HTTP 500"

JEV_GUARD_CURL="$ROOT/tests/stubs/curl-timeout" jev_query "$p" >/dev/null 2>&1
rc=$?
assert_rc 1 "$rc" "timeout rejeté"
assert_eq "curl_echec" "$JEV_LAST_ERROR" "cause timeout"

# Clé absente : sauvegarde/restauration (pas de sous-shell) pour que
# JEV_LAST_ERROR survive à l'appel et serve à l'assertion suivante.
_cle_sauvegardee=$TYPESAFE_API_KEY
unset TYPESAFE_API_KEY
JEV_GUARD_CURL="$ROOT/tests/stubs/curl-ok" jev_query "$p" >/dev/null 2>&1
rc=$?
export TYPESAFE_API_KEY=$_cle_sauvegardee
assert_rc 1 "$rc" "clé absente rejetée sans appel"
assert_eq "cle_absente" "$JEV_LAST_ERROR" "cause clé absente"

# Succès après une défaillance : la cause précédente ne doit pas fuiter.
JEV_GUARD_CURL="$ROOT/tests/stubs/curl-ok" jev_query "$p" >/dev/null 2>&1
assert_eq "" "$JEV_LAST_ERROR" "cause vidée après un succès"

finish
