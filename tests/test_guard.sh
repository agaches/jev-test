#!/usr/bin/env bash
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export JEV_GUARD_LOG="$tmp/j.jsonl"
export JEV_GUARD_CACHE_DIR="$tmp/c"
export TYPESAFE_API_KEY=cle-de-test
export JEV_GUARD_CURL="$ROOT/tests/stubs/curl-ok"
export CLAUDE_PROJECT_DIR=/projet

entree() { jq -nc --arg t "$1" --argjson i "$2" '{tool_name:$t,tool_input:$i}'; }
lancer() { printf '%s' "$1" | bash "$ROOT/hooks/jev-guard.sh" >"$tmp/out" 2>"$tmp/err"; printf '%s' $?; }

export JEV_GUARD_MODE=active

# Stub curl-ok renvoie destructiveness 0.3 / secret 0.02 → allow
rc=$(lancer "$(entree Bash '{"command":"git status"}')")
assert_eq "0" "$rc" "commande anodine autorisée"

# Pré-filtre : blocage local, aucun appel réseau
export JEV_GUARD_CURL=/bin/false   # tout appel réseau ferait échouer le test
rc=$(lancer "$(entree Bash '{"command":"export K=sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA"}')")
assert_eq "2" "$rc" "pré-filtre bloque"
assert_eq "prefilter" "$(jq -r '.source' "$JEV_GUARD_LOG" | tail -1)" \
  "source = prefilter, donc aucun appel réseau"
assert_eq "0" "$(grep -c 'sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA' "$JEV_GUARD_LOG")" \
  "le secret n'atteint pas le journal"
export JEV_GUARD_CURL="$ROOT/tests/stubs/curl-ok"

# Repli quand Jev échoue
export JEV_GUARD_CURL="$ROOT/tests/stubs/curl-500"
rc=$(lancer "$(entree Bash '{"command":"rm -rf /"}')")
assert_eq "2" "$rc" "repli bloque rm -rf /"
assert_eq "fallback" "$(jq -r '.source' "$JEV_GUARD_LOG" | tail -1)" "source = fallback"
assert_eq "http_500" "$(jq -r '.cause' "$JEV_GUARD_LOG" | tail -1)" \
  "cause du repli journalisée"

# Protocole « ask » : verdict regex = ask (rm -r récursif hors racine), Jev en
# échec (curl-500 toujours actif), mode actif : la décision doit sortir en 0
# avec un permissionDecision "ask" sur stdout.
rc=$(lancer "$(entree Bash '{"command":"rm -r ./build"}')")
assert_eq "0" "$rc" "verdict ask : code de sortie 0"
assert_eq "ask" "$(jq -r '.hookSpecificOutput.permissionDecision' "$tmp/out")" \
  "verdict ask : permissionDecision écrit sur stdout"
export JEV_GUARD_CURL="$ROOT/tests/stubs/curl-ok"

# Contrôle déterministe avant tout appel réseau
export JEV_GUARD_CURL=/bin/false
rc=$(lancer "$(entree Write '{"file_path":"/etc/passwd"}')")
assert_eq "2" "$rc" "chemin hors zone bloqué sans réseau"
export JEV_GUARD_CURL="$ROOT/tests/stubs/curl-ok"

# Outil non concerné
rc=$(lancer "$(entree Read '{"file_path":"/projet/a.ts"}')")
assert_eq "0" "$rc" "outil hors périmètre ignoré"

# Cache : deuxième appel identique sans réseau
lancer "$(entree Bash '{"command":"ls -la"}')" >/dev/null
export JEV_GUARD_CURL=/bin/false
rc=$(lancer "$(entree Bash '{"command":"ls -la"}')")
assert_eq "0" "$rc" "second appel servi par le cache"
assert_eq "cache" "$(jq -r '.source' "$JEV_GUARD_LOG" | tail -1)" "source = cache"
export JEV_GUARD_CURL="$ROOT/tests/stubs/curl-ok"

# Coupure par projet (spec §11) : les étages locaux restent actifs, aucun
# appel réseau ne doit partir (curl = /bin/false le prouverait en échouant).
export JEV_GUARD_DISABLE=1
export JEV_GUARD_CURL=/bin/false
rc=$(lancer "$(entree Bash '{"command":"echo bonjour"}')")
assert_eq "0" "$rc" "JEV_GUARD_DISABLE : commande anodine autorisée sans réseau"
assert_eq "disabled" "$(jq -r '.source' "$JEV_GUARD_LOG" | tail -1)" \
  "JEV_GUARD_DISABLE : source = disabled"
rc=$(lancer "$(entree Bash '{"command":"rm -rf /"}')")
assert_eq "2" "$rc" "JEV_GUARD_DISABLE : les règles locales bloquent toujours rm -rf /"
unset JEV_GUARD_DISABLE
export JEV_GUARD_CURL="$ROOT/tests/stubs/curl-ok"

# Réponse Jev structurellement valide mais sans réponse : traitée comme un
# échec, jamais comme une autorisation silencieuse.
export JEV_GUARD_CURL="$ROOT/tests/stubs/curl-empty"
rc=$(lancer "$(entree Bash '{"command":"echo test-reponse-vide"}')")
assert_eq "fallback" "$(jq -r '.source' "$JEV_GUARD_LOG" | tail -1)" \
  "réponse Jev vide : source = fallback"
assert_eq "reponse_vide" "$(jq -r '.cause' "$JEV_GUARD_LOG" | tail -1)" \
  "réponse Jev vide : cause journalisée"
export JEV_GUARD_CURL="$ROOT/tests/stubs/curl-ok"

# MODE OMBRE : Jev n'a jamais le dernier mot
export JEV_GUARD_MODE=shadow
rc=$(lancer "$(entree Bash '{"command":"git show a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"}')")
assert_eq "2" "$rc" "mode ombre : la regex décide, donc blocage"
assert_eq "allow" "$(jq -r '.verdict' "$JEV_GUARD_LOG" | tail -1)" "verdict Jev journalisé"
assert_eq "block" "$(jq -r '.regex_verdict' "$JEV_GUARD_LOG" | tail -1)" "verdict regex journalisé"
assert_eq "false" "$(jq -r '.agreed' "$JEV_GUARD_LOG" | tail -1)" "désaccord enregistré"

# Latence : champ numérique dès qu'une décision est tranchée par Jev
assert_eq "number" \
  "$(jq -r 'select(.source=="jev") | .latency_ms | type' "$JEV_GUARD_LOG" | tail -1)" \
  "latency_ms est numérique pour une réponse Jev"

finish
