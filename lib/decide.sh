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
  # Un champ absent prend le défaut le plus prudent, pas le plus commode. Pour
  # les scores, c'est 0. Pour les CONFIANCES, c'est 0 aussi : un défaut à 1
  # neutralisait purement et simplement la règle 4 — si l'API omettait le
  # champ, tout ce qui passait sous le seuil de destructivité ressortait en
  # `allow` sans jamais escalader. Avec 0, une confiance absente déclenche la
  # règle 4 et escalade en `ask`. `{"answers":{}}` vaut donc `ask`.
  # Une portée présente mais illisible est ramenée à la plus large, pour que la
  # règle 2 continue de s'appliquer au lieu d'être contournée.
  #
  # `blast_radius.confidence` est extrait et validé en type, mais n'est plus
  # seuillé par la règle 4 (voir le bloc awk). Il reste dans l'extraction pour
  # deux raisons : la validation stricte est un contrat qui vaut pour tous les
  # champs lus, et un type aberrant sur ce champ doit continuer de faire
  # escalader la réponse entière en `ask`.
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
      (.answers.destructiveness.confidence | nombre(0)),
      (.answers.blast_radius.confidence    | nombre(0))
    ] | @tsv' <<<"$r" 2>/dev/null) || { printf ask; return; }

  IFS=$'\t' read -r secret destr blast conf_d conf_b <<<"$champs"

  # Règle 4, porte de confiance : elle ne teste QUE la confiance sur la
  # destructivité. Calibrage mesuré sur 44 appels réels au modèle jev-1.13.0.
  #
  # Pourquoi la portée en est exclue : les règles sont évaluées dans l'ordre et
  # la règle 3 (`d >= tda`, 1.5 par défaut) renvoie déjà `ask`. La règle 4 ne
  # voit donc jamais qu'un score sous 1.5 — une bande où `blast_radius`
  # n'intervient dans aucune règle, la seule qui le lise étant la règle 2, qui
  # exige `d >= tdb` (2.5). Une confiance faible sur la portée ne portait donc
  # aucune décision : elle ne faisait qu'interrompre. Et le modèle est
  # structurellement incertain sur la portée des commandes sans effet — « jusqu'où
  # porte l'effet » ne veut rien dire pour une lecture — ce qui interrompait
  # 15 à 30 % du trafic ordinaire sur des commandes inoffensives.
  #
  # `destructiveness.confidence` reste seuillée : si elle est faible, c'est le
  # score lui-même qui n'est pas fiable, et il pourrait valoir plus de 1.5.
  #
  # `cb` n'est volontairement plus passé à awk : il n'y est plus lu.
  awk -v s="$secret" -v d="$destr" -v b="$blast" \
      -v cd="$conf_d" \
      -v ts="${JEV_T_SECRET:-0.85}" \
      -v tdb="${JEV_T_DESTRUCT_BLOCK:-2.5}" \
      -v tda="${JEV_T_DESTRUCT_ASK:-1.5}" \
      -v tc="${JEV_T_CONFIDENCE:-0.60}" '
    BEGIN {
      if (s > ts)                                                  { print "block"; exit }
      if (d >= tdb && (b == "machine" || b == "shared_remote"))     { print "block"; exit }
      if (d >= tda)                                                { print "ask";   exit }
      if (cd < tc)                                                 { print "ask";   exit }
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
