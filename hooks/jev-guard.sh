#!/usr/bin/env bash
# Hook PreToolUse unique, adossé à Jev (spec §5).
# Remplace dangerous-actions-blocker.sh et security-check.sh.
#
# Sortie : code 0 = autoriser, code 2 + stderr = bloquer,
#          JSON hookSpecificOutput = demander confirmation.

set -uo pipefail

# EPOCHREALTIME suit le séparateur décimal de la locale, et les comparaisons
# flottantes d'awk dans decide.sh en dépendent aussi. Locale numérique fixe.
export LC_ALL=C

_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)
. "$_LIB/prefilter.sh"
. "$_LIB/log.sh"
. "$_LIB/cache.sh"
. "$_LIB/fallback.sh"
. "$_LIB/deterministic.sh"
. "$_LIB/decide.sh"
. "$_LIB/jev-client.sh"

JEV_GUARD_MODE=${JEV_GUARD_MODE:-shadow}

if ! command -v jq >/dev/null 2>&1; then
  printf 'jev-guard inactif : jq est introuvable.\n' >&2
  exit 0
fi

ENTREE=$(cat)
OUTIL=$(jq -r '.tool_name // empty' <<<"$ENTREE" 2>/dev/null)

case "$OUTIL" in
  Bash)        SUJET=$(jq -r '.tool_input.command // empty'   <<<"$ENTREE") ;;
  Edit|Write)  SUJET=$(jq -r '.tool_input.file_path // empty' <<<"$ENTREE") ;;
  *)           exit 0 ;;
esac
[ -n "$SUJET" ] || exit 0

# Horloge en millisecondes. EPOCHREALTIME (bash 5) quand elle existe, repli
# sur une résolution à la seconde sinon.
_maintenant_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    awk -v t="$EPOCHREALTIME" 'BEGIN{printf "%d", t*1000}'
  else
    printf '%d' "$(( $(date +%s) * 1000 ))"
  fi
}

emettre() {
  local verdict=$1 raison=$2
  case "$verdict" in
    block)
      printf 'BLOQUÉ par jev-guard : %s\n' "$raison" >&2
      exit 2 ;;
    ask)
      # Voir Task 8 Step 1 : forme confirmée contre la documentation des hooks.
      jq -nc --arg r "$raison" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "ask",
          permissionDecisionReason: $r
        }}'
      exit 0 ;;
    allow)
      exit 0 ;;
    *)
      # Verdict illisible (cache corrompu, decide_* muet...) : on demande
      # confirmation plutôt que d'autoriser en silence.
      jq -nc --arg r "verdict illisible ($verdict) : $raison" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "ask",
          permissionDecisionReason: $r
        }}'
      exit 0 ;;
  esac
}

REGEX_VERDICT=$(fallback_verdict "$OUTIL" "$SUJET")

# --- Étage 1 : contrôles déterministes (aucun réseau) ---
if [ "$OUTIL" = "Edit" ] || [ "$OUTIL" = "Write" ]; then
  if [ "$(path_containment_verdict "$SUJET")" = "block" ]; then
    log_decision "$OUTIL" "$SUJET" "deterministic" "block" "$REGEX_VERDICT" '{}' null 0
    emettre block "édition hors des zones autorisées : $SUJET"
  fi
  if [ "$REGEX_VERDICT" = "block" ]; then
    log_decision "$OUTIL" "$SUJET" "deterministic" "block" "$REGEX_VERDICT" '{}' null 0
    emettre block "fichier protégé : $(basename "$SUJET")"
  fi
fi

# --- Étage 2 : pré-filtre anti-exfiltration (aucun réseau, spec §7) ---
if MOTIF=$(prefilter_match "$SUJET"); then
  log_decision "$OUTIL" "$SUJET" "prefilter" "block" "$REGEX_VERDICT" '{}' null 0
  emettre block "valeur de secret détectée localement (motif $MOTIF)"
fi

# --- Coupure par projet (spec §11, traitement du risque R1) ---
# Les étages locaux restent actifs : ils ne coûtent rien et n'envoient rien.
if [ -n "${JEV_GUARD_DISABLE:-}" ]; then
  log_decision "$OUTIL" "$SUJET" "disabled" "$REGEX_VERDICT" "$REGEX_VERDICT" \
    '{}' null 0 "desactive"
  emettre "$REGEX_VERDICT" "jev-guard désactivé, règles locales seules"
fi

# --- Étage 3 : cache ---
CLE=$(cache_key "$OUTIL" "$SUJET" "$PWD")
if VERDICT=$(cache_get "$CLE"); then
  log_decision "$OUTIL" "$SUJET" "cache" "$VERDICT" "$REGEX_VERDICT" '{}' null 0
  [ "$JEV_GUARD_MODE" = "shadow" ] && VERDICT=$REGEX_VERDICT
  emettre "$VERDICT" "verdict mémorisé"
fi

# --- Étage 4 : Jev ---
DEBUT=$(_maintenant_ms)
if [ "$OUTIL" = "Bash" ]; then
  EN_GIT=false; git rev-parse --is-inside-work-tree >/dev/null 2>&1 && EN_GIT=true
  PAYLOAD=$(jev_build_bash_payload "$SUJET" "$PWD" "$EN_GIT")
else
  PAYLOAD=$(jev_build_file_payload "$SUJET" "$OUTIL")
fi

# jev_query publie la cause de ses échecs dans la variable globale
# JEV_LAST_ERROR (spec §9). Un « REPONSE=$(jev_query ...) » ferait tourner la
# fonction dans un sous-shell : cette variable ne remonterait jamais jusqu'ici.
# On capture donc sa sortie standard par redirection vers un fichier
# temporaire, en gardant l'appel dans le shell courant. Le gabarit respecte
# explicitement TMPDIR : un simple `mktemp` sans gabarit l'ignore sur
# certains systèmes (macOS notamment).
JEV_SORTIE=$(mktemp "${TMPDIR:-/tmp}/jev-guard.XXXXXX" 2>/dev/null) || JEV_SORTIE=""
# Filet de sécurité : si le hook est tué (timeout) avant le `rm -f` normal,
# ce fichier ne doit pas rester orphelin sur un chemin exécuté à chaque appel.
[ -n "$JEV_SORTIE" ] && trap 'rm -f "$JEV_SORTIE"' EXIT

REPONSE=""
if [ -z "$JEV_SORTIE" ]; then
  # mktemp a échoué (TMPDIR absent/plein/en lecture seule) : Jev n'a jamais
  # pu être interrogé, mais la cause ne doit pas rester silencieuse.
  JEV_LAST_ERROR=mktemp_echec
elif jev_query "$PAYLOAD" >"$JEV_SORTIE" 2>/dev/null; then
  REPONSE=$(cat "$JEV_SORTIE")
fi
rm -f "$JEV_SORTIE"

# Une réponse structurellement valide mais sans réponse ne dit rien : elle ne
# doit jamais autoriser en silence. On la traite comme un échec.
if [ -n "$REPONSE" ] && \
   [ "$(jq -r '(.answers // {}) | length' <<<"$REPONSE" 2>/dev/null || printf 0)" = "0" ]; then
  JEV_LAST_ERROR=reponse_vide
  REPONSE=""
fi

if [ -n "$REPONSE" ]; then
  LATENCE=$(( $(_maintenant_ms) - DEBUT ))
  if [ "$OUTIL" = "Bash" ]; then
    VERDICT=$(decide_bash "$REPONSE")
    # `numbers` filtre tout ce qui n'est pas un nombre (ex. confidence:"high") :
    # sans cela, --argjson refuserait la valeur et log_decision perdrait
    # silencieusement toute la ligne (log.sh:42, `|| true`).
    CONF=$(jq -r '(.answers.destructiveness.confidence | numbers) // null' <<<"$REPONSE")
  else
    VERDICT=$(decide_file "$REPONSE")
    CONF=$(jq -r '(.answers.sensitive_file.confidence | numbers) // null' <<<"$REPONSE")
  fi
  SCORES=$(jq -c '.answers' <<<"$REPONSE")
  cache_put "$CLE" "$VERDICT" "$SCORES"
  log_decision "$OUTIL" "$SUJET" "jev" "$VERDICT" "$REGEX_VERDICT" \
    "$SCORES" "$CONF" "$LATENCE"
else
  # --- Étage 5 : repli ---
  VERDICT=$REGEX_VERDICT
  log_decision "$OUTIL" "$SUJET" "fallback" "$VERDICT" "$REGEX_VERDICT" \
    '{}' null 0 "$JEV_LAST_ERROR"
fi

# En mode ombre, Jev est observé mais ne décide jamais.
[ "$JEV_GUARD_MODE" = "shadow" ] && VERDICT=$REGEX_VERDICT

emettre "$VERDICT" "verdict $JEV_GUARD_MODE"
