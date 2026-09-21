#!/usr/bin/env bash
# Repli en mode dégradé (spec §9).
#
# Reprend les listes de motifs de dangerous-actions-blocker.sh et
# security-check.sh, y compris leurs faux positifs connus (un SHA git pris pour
# une clé, un `token=` en nom de paramètre d'URL) : ces cas-là relèvent de Jev
# en mode nominal, pas d'un durcissement de ce fichier.
#
# Ce n'est PAS une copie conforme du comportement des deux anciens hooks. Un
# point diverge, et c'est assumé : `rm -r`, `rmdir` et `unlink` produisent ici
# un verdict `ask`, donc une demande de confirmation, là où l'ancien hook se
# contentait d'un avertissement et sortait en 0. `rm -rf node_modules` demande
# donc confirmation dès le mode ombre, configuration par défaut. On ne revient
# pas dessus : c'est un plancher, pas une reproduction.
#
# Ne pas relâcher ces règles pour faire taire un faux positif : leur rôle est
# d'être un plancher stable et prévisible quand Jev est indisponible.

_FB_DANGEREUX=(
  'rm -rf /' 'rm -rf ~' 'rm -rf $HOME' 'dd if=' 'mkfs' ':(){:|:&};:'
  '> /dev/sda' 'chmod -R 777 /' 'chown -R' 'sudo rm'
  'DROP DATABASE' 'DROP TABLE' '--no-preserve-root'
)

_FB_SECRETS=(
  'password=' 'secret=' 'api_key=' 'apikey=' 'token='
  'aws_access_key' 'aws_secret' 'private_key'
)

_FB_FICHIERS=(
  '.env' '.env.local' '.env.production' '.env.development'
  'credentials.json' 'serviceAccountKey.json'
  'id_rsa' 'id_ed25519' 'id_ecdsa' '.npmrc' '.pypirc'
  'secrets.yml' 'secrets.yaml'
)

fallback_verdict() {
  local outil=$1 sujet=$2 motif

  if [ "$outil" = "Bash" ]; then
    for motif in "${_FB_DANGEREUX[@]}"; do
      [[ "$sujet" == *"$motif"* ]] && { printf block; return; }
    done
    if grep -qE 'git push.*(-f|--force).*(main|master)' <<<"$sujet"; then
      printf block; return
    fi
    if grep -qE 'npm publish|pnpm publish|yarn publish' <<<"$sujet"; then
      printf block; return
    fi
    for motif in "${_FB_SECRETS[@]}"; do
      grep -qi -- "$motif" <<<"$sujet" && { printf block; return; }
    done
    if grep -qE '(sk-[a-zA-Z0-9]{20,}|pk_[a-zA-Z0-9]{20,}|[a-f0-9]{32,})' <<<"$sujet"; then
      printf block; return
    fi
    if grep -qE 'rm -r|rmdir|unlink' <<<"$sujet"; then
      printf ask; return
    fi
    printf allow; return
  fi

  if [ "$outil" = "Edit" ] || [ "$outil" = "Write" ]; then
    local base; base=$(basename "$sujet")
    for motif in "${_FB_FICHIERS[@]}"; do
      [ "$base" = "$motif" ] && { printf block; return; }
    done
    printf allow; return
  fi

  printf allow
}
