#!/usr/bin/env bash
# Seuillage des probabilités (spec §8.3).
#
# Le modèle fournit des nombres, ce fichier produit la décision. Les cinq
# règles sont évaluées dans l'ordre, la première qui s'applique l'emporte.
# awk est utilisé parce que bash ne compare pas les flottants.

decide_bash() {
  local r=$1 champs
  local secret destr blast conf_d conf_b

  # Extraction stricte. Un champ présent mais du mauvais type rend la réponse
  # illisible : on escalade en `ask`, jamais en `allow`. Sans cette validation,
  # jq n'émet rien, awk reçoit une chaîne vide qui n'est pas un « strnum », la
  # comparaison dégénère en comparaison de chaînes et les cinq règles tombent.
  # Un champ absent garde son défaut sûr : `{"answers":{}}` reste `allow`.
  # Une portée présente mais illisible est ramenée à la plus large, pour que la
  # règle 2 continue de s'appliquer au lieu d'être contournée.
  champs=$(jq -er '
    if type != "object" or (.answers | type) != "object"
    then error("réponse sans objet answers") else . end |
    def nombre($defaut):
      if . == null then $defaut
      elif type == "number" then .
      else error("type inattendu") end;
    def portee:
      if . == null then "cwd"
      elif type == "string" and (. == "cwd" or . == "repo"
           or . == "machine" or . == "shared_remote") then .
      else "shared_remote" end;
    [ (.answers.secret_exposure.noul       | nombre(0)),
      (.answers.destructiveness.score      | nombre(0)),
      (.answers.blast_radius.choice        | portee),
      (.answers.destructiveness.confidence | nombre(1)),
      (.answers.blast_radius.confidence    | nombre(1))
    ] | @tsv' <<<"$r" 2>/dev/null) || { printf ask; return; }

  IFS=$'\t' read -r secret destr blast conf_d conf_b <<<"$champs"

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
  local r=$1 sensible

  # Même extraction stricte que decide_bash : voir le commentaire là-haut.
  sensible=$(jq -er '
    if type != "object" or (.answers | type) != "object"
    then error("réponse sans objet answers") else . end |
    def nombre($defaut):
      if . == null then $defaut
      elif type == "number" then .
      else error("type inattendu") end;
    .answers.sensitive_file.noul | nombre(0)' <<<"$r" 2>/dev/null) || { printf ask; return; }
  awk -v v="$sensible" \
      -v tb="${JEV_T_FILE_BLOCK:-0.80}" \
      -v ta="${JEV_T_FILE_ASK:-0.50}" '
    BEGIN {
      if (v > tb) { print "block"; exit }
      if (v > ta) { print "ask";   exit }
      print "allow"
    }'
}
