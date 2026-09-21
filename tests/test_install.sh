#!/usr/bin/env bash
# Constat I3 : install.sh doit être idempotent, et ne jamais écraser une
# sauvegarde existante.
#
# INTERDIT ABSOLU respecté ici : ce test ne touche JAMAIS le vrai $HOME ni le
# vrai ~/.claude/settings.json. Tout se passe dans un mktemp -d, avec HOME
# surchargé, sur une copie fabriquée pour l'occasion.
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

FAUX_HOME="$tmp/home"
mkdir -p "$FAUX_HOME/.claude"
REGLAGES="$FAUX_HOME/.claude/settings.json"

# Configuration de départ : l'un des deux hooks historiques que l'installateur
# est censé retirer, plus un hook tiers qu'il doit conserver.
jq -n '{
  hooks: {
    PreToolUse: [
      { matcher: "", hooks: [ { type: "command",
        command: "/ancien/dangerous-actions-blocker.sh" } ] },
      { matcher: "Bash", hooks: [ { type: "command",
        command: "/tiers/mon-hook.sh" } ] }
    ]
  }}' > "$tmp/origine.json"
cp "$tmp/origine.json" "$REGLAGES"

installer() { HOME="$FAUX_HOME" bash "$ROOT/install.sh" >/dev/null 2>&1; }

# --- Idempotence : deux exécutions, une seule entrée jev-guard ---
installer
installer

nb=$(jq '[.hooks.PreToolUse[].hooks[].command
          | select(test("jev-guard"))] | length' "$REGLAGES")
assert_eq "1" "$nb" "I3 : exactement une entrée jev-guard après deux installations"

nb=$(jq '[.hooks.PreToolUse[].hooks[].command
          | select(test("dangerous-actions-blocker"))] | length' "$REGLAGES")
assert_eq "0" "$nb" "I3 : le hook historique reste retiré"

nb=$(jq '[.hooks.PreToolUse[].hooks[].command
          | select(test("mon-hook"))] | length' "$REGLAGES")
assert_eq "1" "$nb" "I3 : le hook tiers est conservé"

nb=$(find "$FAUX_HOME/.claude" -name 'settings.json.avant-jev-guard.*' | wc -l)
assert_eq "2" "$(printf '%s' "$nb" | tr -d ' ')" \
  "I3 : deux exécutions, deux sauvegardes distinctes"

# --- Une sauvegarde existante n'est jamais écrasée ---
# La collision de nom est provoquée volontairement : on pré-crée le fichier que
# l'installateur va choisir. Si la seconde a tourné entre notre `date` et le
# sien, la collision n'a pas eu lieu et l'assertion ne prouverait rien : on
# recommence alors, au plus cinq fois.
for essai in 1 2 3 4 5; do
  rm -f "$FAUX_HOME"/.claude/settings.json.avant-jev-guard.*
  cp "$tmp/origine.json" "$REGLAGES"
  sentinelle="$REGLAGES.avant-jev-guard.$(date +%Y%m%d%H%M%S)"
  printf 'SENTINELLE' > "$sentinelle"
  installer
  # Collision avérée si la sentinelle a été écrasée (ancien comportement) ou
  # si l'installateur s'est décalé sur un suffixe (comportement attendu).
  if [ "$(cat "$sentinelle")" != "SENTINELLE" ] || [ -e "$sentinelle.1" ]; then
    break
  fi
done
assert_eq "SENTINELLE" "$(cat "$sentinelle")" \
  "I3 : une sauvegarde existante n'est pas écrasée"
assert_eq "0" "$([ -e "$sentinelle.1" ]; echo $?)" \
  "I3 : la sauvegarde se décale sur un suffixe incrémental"

# --- Le fichier écrit reste exploitable ---
assert_eq "0" "$(jq -e . "$REGLAGES" >/dev/null 2>&1; echo $?)" \
  "I3 : settings.json reste un JSON valide"
assert_eq "$ROOT/hooks/jev-guard.sh" \
  "$(jq -r '[.hooks.PreToolUse[].hooks[].command
             | select(test("jev-guard"))][0]' "$REGLAGES")" \
  "I3 : le hook enregistré est bien celui de ce dépôt"

finish
