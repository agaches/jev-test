#!/usr/bin/env bash
# Harnais d'assertions minimal. Aucune dépendance externe.

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
  local attendu=$1 obtenu=$2 libelle=$3
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$attendu" = "$obtenu" ]; then
    printf '  ok   %s\n' "$libelle"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL %s\n       attendu: [%s]\n       obtenu : [%s]\n' \
      "$libelle" "$attendu" "$obtenu"
  fi
}

assert_rc() {
  local attendu=$1 obtenu=$2 libelle=$3
  assert_eq "$attendu" "$obtenu" "$libelle (code retour)"
}

finish() {
  printf '  --- %d assertions, %d en échec\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
  exit 0
}
