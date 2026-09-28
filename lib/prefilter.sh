#!/usr/bin/env bash
# Pré-filtre anti-exfiltration (spec §7).
#
# Ne cible QUE des formats de VALEURS de secrets non ambigus. Jamais des noms
# de variables comme `token=`, sans quoi on réintroduirait le faux positif que
# tout ce chantier cherche à supprimer.
#
# Critère d'ajout d'un motif : il doit être impossible qu'il corresponde à un
# identifiant de commit, un hachage, un UUID ou une URL publique. Seule
# exception : un UUID n'est admis que précédé d'un nom de secret (voir le motif
# Scaleway plus bas), jamais nu.

JEV_MOTIFS_SECRETS=(
  'sk-[A-Za-z0-9_-]{20,}'
  'AKIA[0-9A-Z]{16}'
  'ghp_[A-Za-z0-9]{36}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  # Clé d'accès Scaleway : SCW + 17 caractères, jamais un SHA ni un UUID.
  'SCW[A-Z0-9]{17}'
  # Clé d'API TypeSafe (Jev).
  'apikey_[0-9a-f]{32,}'
  # Clé secrète Scaleway : un UUID nu est indiscernable d'un identifiant de
  # ressource, donc l'UUID n'est accepté que derrière un nom de secret.
  '(secret[-_]key|SECRET[-_]KEY|[Xx]-[Aa]uth-[Tt]oken)["'\'']?[[:space:]=:]+["'\'']?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
)

# Variables d'environnement dont la VALEUR ne doit jamais apparaître dans une
# commande. Filet exact pour les secrets sans format propre (l'UUID Scaleway) :
# on compare à la valeur réellement exportée dans l'environnement du hook.
# Surchargeable via JEV_GUARD_SECRET_VARS, séparée par des espaces.
JEV_VARS_SECRETS=${JEV_GUARD_SECRET_VARS:-'SCW_SECRET_KEY SCW_ACCESS_KEY TYPESAFE_API_KEY'}

# Texte substitué à la commande entière dès qu'un motif de secret est reconnu.
# Constante volontairement reconnaissable dans le journal.
JEV_CMD_RETENUE='[commande retenue : secret détecté]'

# Correspondance évaluée par l'opérateur `=~` de bash, pas par `grep` : ce
# fichier est sur le chemin de CHAQUE appel d'outil, et le cas courant (aucun
# motif) coûte ainsi zéro fork au lieu de cinq. Les motifs sont des ERE POSIX,
# lus par la même bibliothèque que `grep -E`.
prefilter_match() {
  local texte=$1 motif nom valeur
  for motif in "${JEV_MOTIFS_SECRETS[@]}"; do
    if [[ "$texte" =~ $motif ]]; then
      printf '%s' "$motif"
      return 0
    fi
  done
  # Valeur exacte d'une variable secrète. On n'émet que son NOM : ce retour
  # finit dans le journal (`cause`) et dans le message de blocage. Les valeurs
  # de moins de 8 caractères sont ignorées : trop courtes pour être un secret,
  # et susceptibles de correspondre à n'importe quoi.
  for nom in $JEV_VARS_SECRETS; do
    valeur=${!nom:-}
    [ "${#valeur}" -ge 8 ] || continue
    if [[ "$texte" == *"$valeur"* ]]; then
      printf 'env:%s' "$nom"
      return 0
    fi
  done
  return 1
}

# Rédaction pour le journal.
#
# On ne tente PAS d'expurger « le morceau qui a matché » : sur les motifs d'origine,
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
