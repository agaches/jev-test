#!/usr/bin/env bash
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/lib/deterministic.sh"

export CLAUDE_PROJECT_DIR=/projet
unset ALLOWED_PATHS

assert_eq allow "$(path_containment_verdict /projet/src/a.ts)" "dans le projet"
assert_eq allow "$(path_containment_verdict /projet)"           "la racine du projet elle-même"
assert_eq block "$(path_containment_verdict /projet-evil/x)"    "répertoire frère du projet"
assert_eq allow "$(path_containment_verdict "$HOME/.claude/settings.json")" "dans ~/.claude"
assert_eq allow "$(path_containment_verdict /tmp/scratch.txt)"  "dans /tmp"
assert_eq block "$(path_containment_verdict /etc/passwd)"       "hors zones autorisées"
assert_eq block "$(path_containment_verdict "$HOME/Documents/x")" "hors zones autorisées"
assert_eq block "$(path_containment_verdict /tmpfoo/x)"         "répertoire frère de /tmp"

export ALLOWED_PATHS=/opt/data:/srv/www
assert_eq allow "$(path_containment_verdict /opt/data/f.csv)" "zone supplémentaire 1"
assert_eq allow "$(path_containment_verdict /srv/www/i.html)" "zone supplémentaire 2"
assert_eq block "$(path_containment_verdict /opt/autre/f)"    "hors zone supplémentaire"

export CLAUDE_PROJECT_DIR=/projet
unset ALLOWED_PATHS
assert_eq block "$(path_containment_verdict /projet/../../etc/hosts)"      "traversée hors projet"
assert_eq allow "$(path_containment_verdict /projet/src/../lib/b.ts)"      "traversée interne au projet"
assert_eq allow "$(path_containment_verdict /projet/./src/a.ts)"           "segment . redondant"
assert_eq block "$(path_containment_verdict tmp/x)"                        "chemin relatif non rendu absolu"
assert_eq block "$(path_containment_verdict "$HOME/.claude/../Documents/x")" "traversée hors ~/.claude"

finish
