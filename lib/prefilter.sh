#!/usr/bin/env bash
# Pré-filtre anti-exfiltration (spec §7).
#
# Ne cible QUE des formats de VALEURS de secrets non ambigus. Jamais des noms
# de variables comme `token=`, sans quoi on réintroduirait le faux positif que
# tout ce chantier cherche à supprimer.
#
# Critère d'ajout d'un motif : il doit être impossible qu'il corresponde à un
# identifiant de commit, un hachage, un UUID ou une URL publique.

JEV_MOTIFS_SECRETS=(
  'sk-[A-Za-z0-9_-]{20,}'
  'AKIA[0-9A-Z]{16}'
  'ghp_[A-Za-z0-9]{36}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

prefilter_match() {
  local texte=$1 motif
  for motif in "${JEV_MOTIFS_SECRETS[@]}"; do
    if printf '%s' "$texte" | grep -qE -- "$motif"; then
      printf '%s' "$motif"
      return 0
    fi
  done
  return 1
}

prefilter_redact() {
  local texte=$1 motif
  for motif in "${JEV_MOTIFS_SECRETS[@]}"; do
    texte=$(printf '%s' "$texte" | sed -E "s|$motif|[REDACTED]|g")
  done
  printf '%s' "$texte"
}
