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

# Texte substitué à la commande entière dès qu'un motif de secret est reconnu.
# Constante volontairement reconnaissable dans le journal.
JEV_CMD_RETENUE='[commande retenue : secret détecté]'

# Correspondance évaluée par l'opérateur `=~` de bash, pas par `grep` : ce
# fichier est sur le chemin de CHAQUE appel d'outil, et le cas courant (aucun
# motif) coûte ainsi zéro fork au lieu de cinq. Les motifs sont des ERE POSIX,
# lus par la même bibliothèque que `grep -E`.
prefilter_match() {
  local texte=$1 motif
  for motif in "${JEV_MOTIFS_SECRETS[@]}"; do
    if [[ "$texte" =~ $motif ]]; then
      printf '%s' "$motif"
      return 0
    fi
  done
  return 1
}

# Rédaction pour le journal.
#
# On ne tente PAS d'expurger « le morceau qui a matché » : sur les cinq motifs,
# deux ne couvrent que l'en-tête ou l'identifiant public du secret. Un bloc PEM
# verrait son en-tête remplacé et le corps de la clé partir en clair ; un
# `aws configure set aws_secret_access_key <valeur> ; echo AKIA…` verrait
# l'identifiant masqué et la clé secrète passer intacte. Élargir les motifs
# pour couvrir les valeurs est un jeu qui se perd : ne rien écrire est la seule
# garantie.
#
# Dès qu'un motif est reconnu, la commande entière est donc retenue. Ce qui
# reste au journal suffit à l'analyse de phase A : `cmd_sha256`, calculé par
# log_decision sur la commande RÉELLE, et le nom du motif, journalisé par
# l'appelant dans le champ `cause`.
#
# `prefilter_match` sert aussi de garde : hors secret, aucun `sed` n'est lancé.
prefilter_redact() {
  local texte=$1
  if prefilter_match "$texte" >/dev/null; then
    printf '%s' "$JEV_CMD_RETENUE"
    return 0
  fi
  printf '%s' "$texte"
}
