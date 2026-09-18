#!/usr/bin/env bash
# Contrôles déterministes de chemin (spec §6).
# Repris de dangerous-actions-blocker.sh:106-130. Comparaison de préfixe
# exacte : correcte, gratuite, aucun appel réseau.
#
# Le préfixe doit couvrir un segment entier : une zone autorisée `/projet`
# couvre `/projet` et `/projet/...`, jamais le répertoire frère `/projet-evil`.

_prefixe_couvre() {
  local prefixe=$1 chemin=$2
  [ -n "$prefixe" ] || return 1
  prefixe=${prefixe%/}
  [ "$chemin" = "$prefixe" ] || [[ "$chemin" == "$prefixe"/* ]]
}

path_containment_verdict() {
  local chemin=$1
  local projet="${CLAUDE_PROJECT_DIR:-$PWD}"
  local claude_home="$HOME/.claude"
  local autorise=1

  _prefixe_couvre "$projet" "$chemin"      && autorise=0
  _prefixe_couvre "$claude_home" "$chemin" && autorise=0
  _prefixe_couvre /tmp "$chemin"           && autorise=0

  if [ -n "${ALLOWED_PATHS:-}" ]; then
    local zone
    local -a _zones
    IFS=':' read -ra _zones <<< "$ALLOWED_PATHS"
    for zone in "${_zones[@]}"; do
      _prefixe_couvre "$zone" "$chemin" && autorise=0
    done
  fi

  [ "$autorise" -eq 0 ] && printf allow || printf block
}
