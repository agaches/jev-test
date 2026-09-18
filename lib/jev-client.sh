#!/usr/bin/env bash
# Transport vers l'API Jev (spec §8.1). Aucune décision ici.

JEV_GUARD_ENDPOINT=${JEV_GUARD_ENDPOINT:-https://api.typesafe.ai/v1/systemone}

# Cause de la dernière défaillance de jev_query, publiée pour le journal
# (spec §9 : chaque repli en mode dégradé doit être journalisé avec sa cause).
# Remise à vide au début de chaque appel : un succès ne doit jamais laisser
# fuiter la cause d'un échec précédent vers une ligne de journal ultérieure.
JEV_LAST_ERROR=""

_JEV_RUBRIQUE_DESTRUCTION='[
  "Aucune modification d'\''état : lecture, inspection, affichage, recherche.",
  "Modification réversible sans effort : création de fichier, écriture dans un fichier suivi par git, installation de dépendance locale.",
  "Perte possible de travail local non sauvegardé : reset, checkout destructif, stash drop, suppression de fichiers non suivis, réécriture d'\''historique local.",
  "Destruction irréversible ou effet hors de la machine : suppression récursive large, force-push, suppression de branche distante, drop de base, publication de paquet, écriture sur un périphérique bloc."
]'

_JEV_PORTEES='{
  "cwd": "L'\''effet reste dans le répertoire de travail courant.",
  "repo": "L'\''effet touche le dépôt local au-delà du répertoire courant.",
  "machine": "L'\''effet touche la machine hors du dépôt : système, paquets globaux, répertoire personnel, configuration utilisateur.",
  "shared_remote": "L'\''effet est visible par d'\''autres : dépôt distant, service déployé, base de données partagée, registre de paquets."
}'

# La seconde phrase de cette instruction est ce qui corrige le faux positif
# sur les SHA git : elle exclut explicitement la classe d'objets que la regex
# actuelle confond avec une clé d'API.
_JEV_INSTR_SECRET="La commande contient-elle la VALEUR d'un secret en clair (clé d'API, jeton, mot de passe, clé privée) ? Répondre non si la commande ne fait que nommer une variable d'environnement, lire un secret depuis un fichier ou un gestionnaire de secrets, ou contenir un identifiant de commit, un hachage ou un UUID."

jev_build_bash_payload() {
  jq -n \
    --arg model "${JEV_GUARD_MODEL:-jev-latest}" \
    --arg cmd "$1" --arg cwd "$2" --argjson git "$3" \
    --argjson rubrique "$_JEV_RUBRIQUE_DESTRUCTION" \
    --argjson portees "$_JEV_PORTEES" \
    --arg instr_secret "$_JEV_INSTR_SECRET" '
    {
      model: $model,
      state: { tool: "Bash", command: $cmd, cwd: $cwd, in_git_repo: $git },
      questions: {
        destructiveness: {
          type: "score",
          instructions: "À quel point cette commande shell est-elle destructrice ou irréversible ?",
          criteria: $rubrique
        },
        secret_exposure: { type: "noul", instructions: $instr_secret },
        blast_radius: {
          type: "choice",
          instructions: "Jusqu'\''où porte l'\''effet de cette commande ?",
          criteria: $portees
        }
      }
    }'
}

jev_build_file_payload() {
  jq -n \
    --arg model "${JEV_GUARD_MODEL:-jev-latest}" \
    --arg path "$1" --arg tool "$2" '
    {
      model: $model,
      state: { tool: $tool, path: $path },
      questions: {
        sensitive_file: {
          type: "noul",
          instructions: "Ce chemin désigne-t-il un fichier contenant des secrets, des identifiants, une clé privée ou une configuration de production sensible ?"
        }
      }
    }'
}

jev_query() {
  local payload=$1 brut code corps timeout_s
  JEV_LAST_ERROR=""

  if [ -z "${TYPESAFE_API_KEY:-}" ]; then
    JEV_LAST_ERROR="cle_absente"
    return 1
  fi

  timeout_s=$(awk -v ms="${JEV_GUARD_TIMEOUT_MS:-1500}" 'BEGIN{printf "%.3f", ms/1000}')

  brut=$("${JEV_GUARD_CURL:-curl}" -sS -w '\n%{http_code}' \
      --max-time "$timeout_s" \
      -H "Authorization: Bearer $TYPESAFE_API_KEY" \
      -H 'Content-Type: application/json' \
      -d "$payload" "$JEV_GUARD_ENDPOINT" 2>/dev/null) || {
    JEV_LAST_ERROR="curl_echec"
    return 1
  }

  code=${brut##*$'\n'}
  corps=${brut%$'\n'*}

  [[ "$code" =~ ^2[0-9][0-9]$ ]] || {
    JEV_LAST_ERROR="http_${code}"
    return 1
  }

  jq -e . >/dev/null 2>&1 <<<"$corps" || {
    JEV_LAST_ERROR="json_invalide"
    return 1
  }

  printf '%s' "$corps"
}
