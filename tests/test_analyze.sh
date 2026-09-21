#!/usr/bin/env bash
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
journal="$tmp/j.jsonl"

ligne() {
  jq -nc --arg t "$1" --arg v "$2" --arg r "$3" --arg s "$4" --argjson l "$5" \
    '{tool:$t,cmd_redacted:"x",source:$s,verdict:$v,regex_verdict:$r,
      agreed:($v==$r),latency_ms:$l}' >> "$journal"
}
ligne Bash allow allow jev      100
ligne Bash allow block jev      200
ligne Bash block block jev      150
ligne Bash allow allow fallback 0
ligne Edit allow allow deterministic 0
ligne Bash allow allow cache    0

rapport=$(bash "$ROOT/tools/analyze-shadow-log.sh" "$journal")

# Extrait la valeur à droite du « : » pour la ligne dont le libellé est donné.
valeur() { sed -n "s/^ *$1 *: *//p" <<<"$rapport" | head -1 | tr -d ' %'; }

assert_eq "6"  "$(valeur 'Décisions totales')"          "compte total"
assert_eq "5"  "$(valeur 'Décisions Bash')"             "compte Bash seul"
assert_eq "1"  "$(valeur 'Désaccords')"                 "compte désaccords"
assert_eq "1"  "$(valeur 'Jev autorise, regex bloque')" "désaccord le plus sensible"
assert_eq "0"  "$(valeur 'Jev bloque, regex autorise')" "désaccord inverse"
assert_eq "4"  "$(valeur 'Décisions soumises à Jev')"   "dénominateur du taux de repli"
assert_eq "1"  "$(valeur 'Replis (mode dégradé)')"      "compte replis"
assert_eq "25" "$(valeur 'Taux de repli')"              "taux de repli sur décisions soumises"

finish
