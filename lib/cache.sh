#!/usr/bin/env bash
# Cache de scores sur disque (spec §9).
# Indexé par (outil, sujet, cwd). Ne stocke jamais le sujet en clair.

JEV_GUARD_CACHE_DIR=${JEV_GUARD_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/jev-guard}
JEV_CACHE_TTL=${JEV_CACHE_TTL:-604800}   # 7 jours

cache_key() {
  printf '%s\0%s\0%s' "$1" "$2" "$3" | _sha256
}

# Renvoie les SCORES mémorisés, jamais le verdict.
#
# Le répertoire de cache est en écriture pour l'utilisateur et la clé est un
# sha256 de trois champs connus (outil, sujet, cwd) : y déposer un fichier ne
# demande ni `Edit` ni `Write`, donc le confinement de chemin ne s'y applique
# pas. Servir un `.verdict` relu du cache revenait à laisser deux commandes
# Bash — la première anodine, pour semer l'entrée — faire autoriser la seconde.
#
# L'appelant rejoue donc `decide_bash` / `decide_file` sur ces scores. Deux
# effets d'un coup : un `.verdict` forgé n'a plus aucune prise, et les seuils
# redeviennent vivants — un seuil réajusté (critère 6 de la phase A) s'applique
# immédiatement au lieu d'attendre l'expiration des sept jours de TTL.
cache_get_scores() {
  local fichier="$JEV_GUARD_CACHE_DIR/$1.json" ts maintenant
  [ -f "$fichier" ] || return 1
  ts=$(jq -r '.ts_epoch // 0' "$fichier" 2>/dev/null) || return 1
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  maintenant=$(date +%s)
  if [ $(( maintenant - ts )) -ge "$JEV_CACHE_TTL" ]; then
    rm -f "$fichier"
    return 1
  fi
  jq -c '.scores' "$fichier" 2>/dev/null || return 1
}

# `verdict` n'est écrit que pour le diagnostic humain : plus rien ne le relit.
# Ne pas réintroduire de lecture de ce champ.
cache_put() {
  mkdir -p "$JEV_GUARD_CACHE_DIR" 2>/dev/null || return 0
  jq -nc --arg verdict "$2" --argjson scores "${3:-null}" \
         --argjson ts "$(date +%s)" \
         '{$verdict,$scores,ts_epoch:$ts}' \
    > "$JEV_GUARD_CACHE_DIR/$1.json" 2>/dev/null || true
}
