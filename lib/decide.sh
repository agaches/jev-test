#!/usr/bin/env bash
# Seuillage des probabilités (spec §8.3).
#
# Le modèle fournit des nombres, ce fichier produit la décision. Les cinq
# règles sont évaluées dans l'ordre, la première qui s'applique l'emporte.
# awk est utilisé parce que bash ne compare pas les flottants.

decide_bash() {
  local r=$1
  # Une réponse illisible n'autorise jamais en silence : escalade en `ask`.
  # Distinct d'un JSON valide aux champs absents, qui garde ses défauts sûrs.
  jq -e . >/dev/null 2>&1 <<<"$r" || { printf ask; return; }

  local secret destr blast conf_d conf_b
  secret=$(jq -r '.answers.secret_exposure.noul      // 0'     <<<"$r")
  destr=$( jq -r '.answers.destructiveness.score     // 0'     <<<"$r")
  blast=$( jq -r '.answers.blast_radius.choice       // "cwd"' <<<"$r")
  conf_d=$(jq -r '.answers.destructiveness.confidence // 1'    <<<"$r")
  conf_b=$(jq -r '.answers.blast_radius.confidence    // 1'    <<<"$r")

  awk -v s="$secret" -v d="$destr" -v b="$blast" \
      -v cd="$conf_d" -v cb="$conf_b" \
      -v ts="${JEV_T_SECRET:-0.85}" \
      -v tdb="${JEV_T_DESTRUCT_BLOCK:-2.5}" \
      -v tda="${JEV_T_DESTRUCT_ASK:-1.5}" \
      -v tc="${JEV_T_CONFIDENCE:-0.60}" '
    BEGIN {
      if (s > ts)                                                  { print "block"; exit }
      if (d >= tdb && (b == "machine" || b == "shared_remote"))     { print "block"; exit }
      if (d >= tda)                                                { print "ask";   exit }
      if (cd < tc || cb < tc)                                      { print "ask";   exit }
      print "allow"
    }'
}

decide_file() {
  local r=$1
  # Une réponse illisible n'autorise jamais en silence : escalade en `ask`.
  # Distinct d'un JSON valide aux champs absents, qui garde ses défauts sûrs.
  jq -e . >/dev/null 2>&1 <<<"$r" || { printf ask; return; }

  local sensible
  sensible=$(jq -r '.answers.sensitive_file.noul // 0' <<<"$r")
  awk -v v="$sensible" \
      -v tb="${JEV_T_FILE_BLOCK:-0.80}" \
      -v ta="${JEV_T_FILE_ASK:-0.50}" '
    BEGIN {
      if (v > tb) { print "block"; exit }
      if (v > ta) { print "ask";   exit }
      print "allow"
    }'
}
