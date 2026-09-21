#!/usr/bin/env bash
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

CIBLE=""
ligne() {
  jq -nc --arg t "$1" --arg v "$2" --arg r "$3" --arg s "$4" --argjson l "$5" \
    '{tool:$t,cmd_redacted:"x",source:$s,verdict:$v,regex_verdict:$r,
      agreed:($v==$r),latency_ms:$l}' >> "$CIBLE"
}

# Extrait la valeur à droite du « : » pour la ligne dont le libellé est donné.
valeur() { sed -n "s/^ *$1 *: *//p" <<<"$rapport" | head -1 | tr -d ' %ms'; }
# Verdict du critère numéroté, texte brut à droite du « : ».
critere() { sed -n "s/^ *$1\. [^:]*: *//p" <<<"$rapport" | head -1; }

# --- Cas 1 : journal mixte, les deux sens de désaccord représentés.
CIBLE="$tmp/mixte.jsonl"
ligne Bash allow allow jev          100
ligne Bash allow block jev          200
ligne Bash block block jev          150
ligne Bash block allow jev          300
ligne Bash allow allow fallback     0
ligne Edit allow allow deterministic 0
ligne Bash allow allow cache        0

rapport=$(bash "$ROOT/tools/analyze-shadow-log.sh" "$CIBLE")

assert_eq "7"   "$(valeur 'Décisions totales')"          "compte total"
assert_eq "6"   "$(valeur 'Décisions Bash')"             "compte Bash seul"
assert_eq "2"   "$(valeur 'Désaccords')"                 "compte désaccords"
assert_eq "1"   "$(valeur 'Jev autorise, regex bloque')" "désaccord le plus sensible"
assert_eq "1"   "$(valeur 'Jev bloque, regex autorise')" "désaccord inverse"
assert_eq "5"   "$(valeur 'Décisions soumises à Jev')"   "dénominateur du taux de repli"
assert_eq "1"   "$(valeur 'Replis (mode dégradé)')"      "compte replis"
assert_eq "20"  "$(valeur 'Taux de repli')"              "taux de repli sur décisions soumises"
assert_eq "300" "$(valeur 'Latence Jev p95')"            "p95 sur les seules lignes jev"

assert_eq "NON" "$(critere 1)" "critère 1 sous le seuil de 200"
assert_eq "OUI" "$(critere 4)" "critère 4 sous 800 ms"
assert_eq "NON" "$(critere 5)" "critère 5 au-dessus de 5 %"

# --- Cas 2 : aucune décision soumise à Jev. Sans donnée n'est pas OUI.
CIBLE="$tmp/sans-jev.jsonl"
ligne Bash allow allow cache         0
ligne Edit allow allow deterministic 0

rapport=$(bash "$ROOT/tools/analyze-shadow-log.sh" "$CIBLE")

assert_eq "sans donnée" "$(critere 4)" "critère 4 sans latence mesurée"
assert_eq "sans donnée" "$(critere 5)" "critère 5 sans décision soumise"

# --- Cas 3 : latence nulle sur une ligne jev, tolérée sans bruit.
CIBLE="$tmp/latence-nulle.jsonl"
ligne Bash allow allow jev null
ligne Bash allow allow jev 100

rapport=$(bash "$ROOT/tools/analyze-shadow-log.sh" "$CIBLE")
erreurs=$(bash "$ROOT/tools/analyze-shadow-log.sh" "$CIBLE" 2>&1 >/dev/null)

assert_eq "100" "$(valeur 'Latence Jev p95')" "p95 ignore les latences non numériques"
assert_eq ""    "$erreurs"                    "aucun bruit sur stderr"

finish
