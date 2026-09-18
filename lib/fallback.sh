#!/usr/bin/env bash
# Repli en mode dégradé (spec §9).
#
# Reprend à l'identique les règles de dangerous-actions-blocker.sh et
# security-check.sh. Reproduit le comportement actuel, faux positifs compris.
# Ne pas « améliorer » ces règles : leur rôle est d'être un plancher stable et
# prévisible quand Jev est indisponible.

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
