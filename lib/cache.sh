#!/usr/bin/env bash
# Cache de verdicts sur disque (spec §9).
# Indexé par (outil, sujet, cwd). Ne stocke jamais le sujet en clair.

JEV_GUARD_CACHE_DIR=${JEV_GUARD_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/jev-guard}
JEV_CACHE_TTL=${JEV_CACHE_TTL:-604800}   # 7 jours

cache_key() {
  printf '%s\0%s\0%s' "$1" "$2" "$3" | _sha256
}

cache_get() {
  local fichier="$JEV_GUARD_CACHE_DIR/$1.json" ts maintenant
  [ -f "$fichier" ] || return 1
  ts=$(jq -r '.ts_epoch // 0' "$fichier" 2>/dev/null) || return 1
  maintenant=$(date +%s)
  if [ $(( maintenant - ts )) -ge "$JEV_CACHE_TTL" ]; then
    rm -f "$fichier"
    return 1
  fi
  jq -r '.verdict' "$fichier"
}

cache_put() {
  mkdir -p "$JEV_GUARD_CACHE_DIR" 2>/dev/null || return 0
  jq -nc --arg verdict "$2" --argjson scores "${3:-null}" \
         --argjson ts "$(date +%s)" \
         '{$verdict,$scores,ts_epoch:$ts}' \
    > "$JEV_GUARD_CACHE_DIR/$1.json" 2>/dev/null || true
}
