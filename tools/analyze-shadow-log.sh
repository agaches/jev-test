#!/usr/bin/env bash
# Rapport de phase A (spec §10). Alimente les six critères de passage.
set -uo pipefail

JOURNAL=${1:-${JEV_GUARD_LOG:-$HOME/.claude/logs/jev-guard.jsonl}}
[ -f "$JOURNAL" ] || { printf 'Journal introuvable : %s\n' "$JOURNAL" >&2; exit 1; }

total=$(wc -l < "$JOURNAL" | tr -d ' ')
[ "$total" -gt 0 ] || { printf 'Journal vide\n'; exit 0; }

bash_total=$(jq -s '[.[] | select(.tool == "Bash")] | length' "$JOURNAL")
desaccords=$(jq -s '[.[] | select(.agreed == false)] | length' "$JOURNAL")
jev_allow_regex_block=$(jq -s \
  '[.[] | select(.verdict == "allow" and .regex_verdict == "block")] | length' "$JOURNAL")
jev_block_regex_allow=$(jq -s \
  '[.[] | select(.verdict == "block" and .regex_verdict == "allow")] | length' "$JOURNAL")
consultees=$(jq -s \
  '[.[] | select(.source == "jev" or .source == "fallback")] | length' "$JOURNAL")
replis=$(jq -s '[.[] | select(.source == "fallback")] | length' "$JOURNAL")
if [ "$consultees" -gt 0 ]; then
  taux_repli=$(awk -v r="$replis" -v c="$consultees" 'BEGIN{printf "%.0f", 100*r/c}')
else
  taux_repli=0
fi
p95=$(jq -s '[.[] | select(.source=="jev") | .latency_ms] | sort
             | if length == 0 then 0 else .[(length * 0.95 | floor)] end' "$JOURNAL")

cat <<EOF
Rapport de phase A — $JOURNAL

Décisions totales           : $total
Décisions Bash              : $bash_total
Désaccords                  : $desaccords
Jev autorise, regex bloque  : $jev_allow_regex_block
Jev bloque, regex autorise  : $jev_block_regex_allow
Décisions soumises à Jev    : $consultees
Replis (mode dégradé)       : $replis
Taux de repli               : $taux_repli %
Latence Jev p95             : $p95 ms

Critères de passage en mode actif (spec §10) :
  1. >= 200 décisions Bash          : $([ "$bash_total" -ge 200 ] && echo OUI || echo NON)
  2. désaccords bloquants relus     : manuel
  3. aucun allow Jev / block regex justifié : $jev_allow_regex_block à relire
  4. p95 < 800 ms                   : $([ "$p95" -lt 800 ] && echo OUI || echo NON)
  5. taux de repli < 5 %            : $([ "$taux_repli" -lt 5 ] && echo OUI || echo NON)
  6. seuils réajustés               : manuel

Désaccords à relire :
EOF

jq -r 'select(.agreed == false)
       | "  [\(.verdict) vs \(.regex_verdict)] \(.cmd_redacted)"' "$JOURNAL"
