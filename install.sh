#!/usr/bin/env bash
# Installe jev-guard en mode ombre dans ~/.claude/settings.json.
# Sauvegarde le fichier existant et retire les deux hooks remplacés.
set -euo pipefail

RACINE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REGLAGES="$HOME/.claude/settings.json"
HOOK="$RACINE/hooks/jev-guard.sh"

for binaire in jq curl; do
  command -v "$binaire" >/dev/null 2>&1 || {
    printf 'Requis et introuvable : %s\n' "$binaire" >&2; exit 1; }
done

[ -f "$REGLAGES" ] || { printf 'Introuvable : %s\n' "$REGLAGES" >&2; exit 1; }
[ -x "$HOOK" ]     || { printf 'Hook non exécutable : %s\n' "$HOOK" >&2; exit 1; }

# Nom de sauvegarde non collisionnant. L'horodatage est à la seconde : deux
# passages dans la même seconde produisaient le même nom, et la sauvegarde
# d'origine était écrasée par la version déjà modifiée — la ligne
# « Restaurer : … » affichée en fin d'exécution devenait alors fausse.
BASE_SAUVEGARDE="$REGLAGES.avant-jev-guard.$(date +%Y%m%d%H%M%S)"
SAUVEGARDE="$BASE_SAUVEGARDE"
suffixe=1
while [ -e "$SAUVEGARDE" ]; do
  SAUVEGARDE="$BASE_SAUVEGARDE.$suffixe"
  suffixe=$((suffixe + 1))
done
cp "$REGLAGES" "$SAUVEGARDE"
printf 'Sauvegarde : %s\n' "$SAUVEGARDE"

# Écriture atomique : la configuration vivante n'est remplacée qu'une fois le
# résultat validé. Une écriture directe la viderait si jq échouait.
TEMPO=$(mktemp "${TMPDIR:-/tmp}/jev-guard-reglages.XXXXXX")
trap 'rm -f "$TEMPO"' EXIT

# `jev-guard` fait partie du filtre de retrait : sans lui, une seconde
# exécution enregistrait le hook une deuxième fois. Conséquences mesurables :
# deux processus et deux appels API facturés par commande, et deux lignes de
# journal par décision — ce qui double le compteur du critère 1, les
# « 200 décisions » étant alors atteintes à 100 commandes réelles.
jq --arg hook "$HOOK" '
  .hooks.PreToolUse = (
    [ .hooks.PreToolUse[]?
      | .hooks |= map(select(
          (.command // "")
          | test("dangerous-actions-blocker|security-check|jev-guard") | not))
      | select((.hooks | length) > 0) ]
    + [ { matcher: "", hooks: [ { type: "command", command: $hook, timeout: 10 } ] } ]
  )
' "$SAUVEGARDE" > "$TEMPO"

jq -e --arg hook "$HOOK" \
  '[.hooks.PreToolUse[].hooks[].command] | index($hook) != null' \
  "$TEMPO" >/dev/null || {
    printf 'Résultat invalide, configuration inchangée : %s\n' "$REGLAGES" >&2
    exit 1
  }

mv "$TEMPO" "$REGLAGES"
trap - EXIT

printf 'jev-guard installé en mode ombre.\n'

if [ -z "${TYPESAFE_API_KEY:-}" ]; then
  printf '\nATTENTION : TYPESAFE_API_KEY absent de l environnement.\n'
  printf 'En l etat, le hook bascule en repli a chaque appel et la phase A ne\n'
  printf 'mesure rien. Voir la section « Clé d API » du README.\n\n'
fi

printf 'Vérifier : jq ".hooks.PreToolUse" %s\n' "$REGLAGES"
printf 'Restaurer : cp %s %s\n' "$SAUVEGARDE" "$REGLAGES"
