#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ROOT

echecs=0
for fichier in "$ROOT"/tests/test_*.sh; do
  [ -e "$fichier" ] || continue
  printf '\n== %s\n' "$(basename "$fichier")"
  bash "$fichier" || echecs=$((echecs + 1))
done

printf '\n'
if [ "$echecs" -gt 0 ]; then
  printf '%d fichier(s) de test en échec\n' "$echecs"
  exit 1
fi
printf 'Tous les tests passent\n'
