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

assert_eq "7"   "$(valeur 'Décisions exploitables')"     "compte total"
assert_eq "6"   "$(valeur 'Décisions Bash')"             "compte Bash seul"
assert_eq "2"   "$(valeur 'Désaccords Jev et cache')"     "compte désaccords"
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

# --- Cas 4 (constat I4) : les blocages locaux ne sont pas des désaccords Jev.
# Un pré-filtre et un confinement de chemin bloquent tous deux là où la regex
# autorise : ce sont des désaccords au sens du champ `agreed`, mais Jev ne les
# a jamais vus. Les compter noyait la liste à relire du critère 2, et faisait
# annoncer « Désaccords : 2 » à côté de « Décisions soumises à Jev : 0 ».
CIBLE="$tmp/sources-melangees.jsonl"
ligne Bash block allow prefilter      0
ligne Edit block allow deterministic  0
ligne Bash block allow disabled       0
ligne Bash allow block jev          120
ligne Bash block allow cache          0
ligne Bash allow allow jev           80

rapport=$(bash "$ROOT/tools/analyze-shadow-log.sh" "$CIBLE")

assert_eq "6" "$(valeur 'Décisions exploitables')" "I4 : les six lignes sont comptées"
assert_eq "2" "$(valeur 'Désaccords Jev et cache')" \
  "I4 : seuls les désaccords jev et cache sont comptés"
assert_eq "1" "$(valeur 'Jev autorise, regex bloque')" \
  "I4 : compteur allow/block restreint à jev et cache"
assert_eq "1" "$(valeur 'Jev bloque, regex autorise')" \
  "I4 : compteur block/allow ignore prefilter, deterministic et disabled"

liste=$(bash "$ROOT/tools/analyze-shadow-log.sh" "$CIBLE" \
        | sed -n '/^Désaccords à relire/,$p' | grep -c '^  \[')
assert_eq "2" "$liste" "I4 : la liste finale ne contient que les lignes jev et cache"

# --- Cas 5 (constat I5) : une ligne illisible ne passe plus en silence.
# Avant : huit `jq -s` en échec, quatre `[: : integer expected` sur stderr, un
# rapport aux champs vides, des critères à NON… et rc=0.
CIBLE="$tmp/illisible.jsonl"
ligne Bash allow allow jev 100
printf 'ceci nest pas du json\n' >> "$CIBLE"
ligne Bash allow allow jev 200
ligne Bash block block jev 150

sortie=$(bash "$ROOT/tools/analyze-shadow-log.sh" "$CIBLE" 2>"$tmp/err")
rc=$?
rapport=$sortie

assert_eq "2" "$rc" "I5 : le code de retour signale le rejet au-delà du seuil"
assert_eq "1" "$(valeur 'Lignes illisibles rejetées')" "I5 : le rejet est annoncé"
assert_eq "3" "$(valeur 'Décisions exploitables')" "I5 : les lignes valides sont exploitées"
assert_eq "3" "$(valeur 'Décisions Bash')" "I5 : les compteurs restent justes"
assert_eq "200" "$(valeur 'Latence Jev p95')" "I5 : le p95 est calculé, pas vide"
assert_eq "1" "$(grep -c 'au-delà du seuil' "$tmp/err")" \
  "I5 : la cause est expliquée sur stderr"
assert_eq "0" "$(grep -c 'integer expected' "$tmp/err")" \
  "I5 : plus de bruit arithmétique sur stderr"

# Sous le seuil, le rejet est annoncé mais le rapport reste exploitable.
CIBLE="$tmp/un-rejet-sur-cent.jsonl"
i=0
while [ "$i" -lt 100 ]; do ligne Bash allow allow jev 100; i=$((i + 1)); done
printf 'tronque\n' >> "$CIBLE"

rapport=$(bash "$ROOT/tools/analyze-shadow-log.sh" "$CIBLE" 2>/dev/null)
rc=$?
assert_eq "0" "$rc" "I5 : sous le seuil, le code de retour reste 0"
assert_eq "1" "$(valeur 'Lignes illisibles rejetées')" \
  "I5 : le rejet est annoncé même sous le seuil"

finish
