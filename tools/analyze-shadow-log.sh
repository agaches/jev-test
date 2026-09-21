#!/usr/bin/env bash
# Rapport de phase A (spec §10). Alimente les six critères de passage.
set -uo pipefail

# Seuil de tolérance aux lignes illisibles, exprimé en pourcentage des lignes
# du journal. Au-delà, le rapport est jugé non représentatif et le script sort
# en 2 : un journal amputé d'une part notable de ses lignes ne peut pas servir
# à trancher le passage en mode actif. En deçà, les lignes rejetées sont
# annoncées dans le rapport et le code de retour reste 0.
SEUIL_REJET_PCT=${JEV_ANALYSE_SEUIL_REJET_PCT:-5}

JOURNAL=${1:-${JEV_GUARD_LOG:-$HOME/.claude/logs/jev-guard.jsonl}}
[ -f "$JOURNAL" ] || { printf 'Journal introuvable : %s\n' "$JOURNAL" >&2; exit 1; }

# `wc -l` compte des SAUTS DE LIGNE, pas des lignes : une dernière ligne
# tronquée, sans `\n` final, n'y figure pas. Le `jq -R` en aval, lui, la lit et
# la rejette — `rejetees` retombait donc à 0 et la décision tronquée
# disparaissait sans que rien ne le signale. C'est exactement la troncature que
# ce garde-fou vise en premier, et celle que produit une écriture interrompue.
# `awk` compte des enregistrements : la ligne partielle en est un.
lignes_brutes=$(awk 'END{print NR}' "$JOURNAL")

# Une seule ligne non-JSON — troncature, édition manuelle, écriture concurrente
# — faisait échouer les huit `jq -s` d'un coup : quatre `[: : integer expected`
# sur stderr, un rapport aux champs vides, des critères à NON… et rc=0. On
# filtre donc en amont, et on compte ce qui a été écarté.
VALIDE=$(mktemp "${TMPDIR:-/tmp}/jev-analyse.XXXXXX") || {
  printf 'Impossible de créer un fichier temporaire\n' >&2; exit 1; }
trap 'rm -f "$VALIDE"' EXIT

jq -Rc 'fromjson? | select(type == "object")' "$JOURNAL" > "$VALIDE" 2>/dev/null

total=$(wc -l < "$VALIDE" | tr -d ' ')
rejetees=$(( lignes_brutes - total ))
[ "$rejetees" -ge 0 ] || rejetees=0

if [ "$lignes_brutes" -gt 0 ]; then
  rejet_pct=$(awk -v r="$rejetees" -v n="$lignes_brutes" 'BEGIN{printf "%.0f", 100*r/n}')
else
  rejet_pct=0
fi

[ "$total" -gt 0 ] || {
  printf 'Journal vide ou entièrement illisible (%d ligne(s) rejetée(s))\n' "$rejetees"
  [ "$rejetees" -gt 0 ] && exit 2
  exit 0
}

# `jev` et `cache` sont les deux seules sources où Jev a réellement pesé sur la
# décision : `cache` sert des scores venus de Jev. `prefilter`, `deterministic`
# et `disabled` sont des blocages locaux que Jev n'a jamais vus — les compter
# comme des désaccords noyait la liste à relire du critère 2 sous du bruit, et
# faisait annoncer « Désaccords : 2 » à côté de « Décisions soumises à Jev : 0 ».
SRC_JEV='(.source == "jev" or .source == "cache")'

bash_total=$(jq -s '[.[] | select(.tool == "Bash")] | length' "$VALIDE")
desaccords=$(jq -s '[.[] | select(.agreed == false and '"$SRC_JEV"')] | length' "$VALIDE")
jev_allow_regex_block=$(jq -s \
  '[.[] | select(.verdict == "allow" and .regex_verdict == "block" and '"$SRC_JEV"')] | length' \
  "$VALIDE")
jev_block_regex_allow=$(jq -s \
  '[.[] | select(.verdict == "block" and .regex_verdict == "allow" and '"$SRC_JEV"')] | length' \
  "$VALIDE")
consultees=$(jq -s \
  '[.[] | select(.source == "jev" or .source == "fallback")] | length' "$VALIDE")
replis=$(jq -s '[.[] | select(.source == "fallback")] | length' "$VALIDE")
if [ "$consultees" -gt 0 ]; then
  taux_repli=$(awk -v r="$replis" -v c="$consultees" 'BEGIN{printf "%.0f", 100*r/c}')
else
  taux_repli=0
fi
mesures=$(jq -s '[.[] | select(.source=="jev") | .latency_ms | numbers] | length' "$VALIDE")
p95=$(jq -s '[.[] | select(.source=="jev") | .latency_ms | numbers] | sort
             | if length == 0 then 0 else .[(length * 0.95 | floor)] end' "$VALIDE")

if [ "$bash_total" -ge 200 ]; then critere1=OUI; else critere1=NON; fi

if [ "$mesures" -eq 0 ]; then
  critere4="sans donnée"
elif [ "$p95" -lt 800 ]; then
  critere4=OUI
else
  critere4=NON
fi

if [ "$consultees" -eq 0 ]; then
  critere5="sans donnée"
elif [ "$taux_repli" -lt 5 ]; then
  critere5=OUI
else
  critere5=NON
fi

cat <<EOF
Rapport de phase A — $JOURNAL

Lignes du journal           : $lignes_brutes
Lignes illisibles rejetées  : $rejetees
Part de lignes rejetées     : $rejet_pct %
Décisions exploitables      : $total
Décisions Bash              : $bash_total
Désaccords Jev et cache     : $desaccords
Jev autorise, regex bloque  : $jev_allow_regex_block
Jev bloque, regex autorise  : $jev_block_regex_allow
Décisions soumises à Jev    : $consultees
Replis (mode dégradé)       : $replis
Taux de repli               : $taux_repli %
Latence Jev p95             : $p95 ms

Les trois lignes de désaccord ne comptent que les décisions où Jev a pesé
(sources « jev » et « cache »). Les blocages locaux — pré-filtre, confinement
de chemin, coupure par projet — en sont exclus : Jev ne les a jamais vus.

Critères de passage en mode actif (spec §10) :
  1. >= 200 décisions Bash          : $critere1
  2. désaccords bloquants relus     : manuel
  3. aucun allow Jev / block regex justifié : $jev_allow_regex_block à relire
  4. p95 < 800 ms                   : $critere4
  5. taux de repli < 5 %            : $critere5
  6. seuils réajustés               : manuel

Désaccords à relire :
EOF

jq -r 'select(.agreed == false and '"$SRC_JEV"')
       | "  [\(.verdict) vs \(.regex_verdict)] \(.cmd_redacted)"' "$VALIDE"

if [ "$rejetees" -gt 0 ] && [ "$rejet_pct" -ge "$SEUIL_REJET_PCT" ]; then
  printf '\n%d ligne(s) illisible(s) sur %d (%d %%), au-delà du seuil de %d %% :\n' \
    "$rejetees" "$lignes_brutes" "$rejet_pct" "$SEUIL_REJET_PCT" >&2
  printf 'ce rapport n est pas representatif du journal.\n' >&2
  exit 2
fi
exit 0
