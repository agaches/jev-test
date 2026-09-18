#!/usr/bin/env bash
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/lib/decide.sh"

reponse() {  # secret destructiveness blast conf_d conf_b
  jq -nc --argjson s "$1" --argjson d "$2" --arg b "$3" \
         --argjson cd "$4" --argjson cb "$5" '{
    answers: {
      secret_exposure: {noul: $s},
      destructiveness: {score: $d, confidence: $cd},
      blast_radius:    {choice: $b, confidence: $cb}
    }}'
}

# Règle 1 : secret
assert_eq block "$(decide_bash "$(reponse 0.90 0.0 cwd 1 1)")" "R1 secret au-dessus du seuil"
assert_eq allow "$(decide_bash "$(reponse 0.80 0.0 cwd 1 1)")" "R1 secret sous le seuil"

# Règle 2 : destructeur ET portée large
assert_eq block "$(decide_bash "$(reponse 0 2.6 shared_remote 1 1)")" "R2 distant partagé"
assert_eq block "$(decide_bash "$(reponse 0 3.0 machine 1 1)")"       "R2 machine"
assert_eq ask   "$(decide_bash "$(reponse 0 2.6 repo 1 1)")"          "R2 portée étroite → R3"

# Règle 3 : destructeur seul
assert_eq ask   "$(decide_bash "$(reponse 0 1.5 cwd 1 1)")" "R3 au seuil"
assert_eq allow "$(decide_bash "$(reponse 0 1.4 cwd 1 1)")" "R3 sous le seuil"

# Règle 4 : porte de confiance (ne peut qu'escalader allow → ask)
assert_eq ask   "$(decide_bash "$(reponse 0 0.2 cwd 0.55 1)")" "R4 confiance destructiveness basse"
assert_eq ask   "$(decide_bash "$(reponse 0 0.2 cwd 1 0.55)")" "R4 confiance blast basse"
assert_eq block "$(decide_bash "$(reponse 0.95 0.2 cwd 0.10 0.10)")" \
  "R4 n'annule jamais un blocage"

# Règle 5
assert_eq allow "$(decide_bash "$(reponse 0 0.1 cwd 0.99 0.99)")" "R5 cas nominal"

# Champs manquants : ne doit pas planter, défauts sûrs
assert_eq allow "$(decide_bash '{"answers":{}}')" "réponse vide → allow"

# Seuils surchargeables (spec R5)
assert_eq block "$(JEV_T_SECRET=0.50 decide_bash "$(reponse 0.60 0 cwd 1 1)")" \
  "seuil secret surchargeable"

# Fichiers
assert_eq block "$(decide_file '{"answers":{"sensitive_file":{"noul":0.85}}}')" "fichier sensible"
assert_eq ask   "$(decide_file '{"answers":{"sensitive_file":{"noul":0.60}}}')" "fichier douteux"
assert_eq allow "$(decide_file '{"answers":{"sensitive_file":{"noul":0.20}}}')" "fichier anodin"

# Entrée non analysable : escalade, jamais une autorisation silencieuse
assert_eq ask "$(decide_bash 'pas du json')" "réponse illisible → ask (bash)"
assert_eq ask "$(decide_file 'pas du json')" "réponse illisible → ask (fichier)"

finish
