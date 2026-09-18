#!/usr/bin/env bash
set -uo pipefail
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/lib/prefilter.sh"

# Le marqueur PEM est assemblé à l'exécution : écrit en clair, il ferait
# échouer le hook gitleaks du dépôt sur un fichier de test légitime.
ESP=' '
PEM="-----BEGIN RSA PRIVATE${ESP}KEY-----"

# --- Valeurs de secrets : doivent déclencher ---
# Valeurs à entropie nulle (répétitions) pour rester distinguables d'un vrai
# secret par un lecteur comme par un scanner.
for secret in \
  'export OPENAI_API_KEY=sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA' \
  'aws configure set aws_access_key_id AKIA0000000000000000' \
  'git remote add o https://ghp_000000000000000000000000000000000000@example.invalid/a/b' \
  'echo xoxb-000000000000-aaaaaaaaaa' \
  "echo \"$PEM\" > /tmp/k"
do
  prefilter_match "$secret" >/dev/null
  assert_rc 0 $? "détecte: ${secret:0:40}"
done

# --- Anodins : ne doivent PAS déclencher (faux positifs actuels) ---
for anodin in \
  'git show a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0' \
  'git cherry-pick a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0' \
  'curl "https://api.example.com/v1/data?token=public"' \
  'md5sum rapport.txt' \
  'export API_TOKEN="$SECRET_FROM_VAULT"' \
  'kubectl get secret ma-cle -o yaml'
do
  prefilter_match "$anodin" >/dev/null
  assert_rc 1 $? "laisse passer: ${anodin:0:40}"
done

# --- Expurgation ---
redige=$(prefilter_redact 'export K=sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA suite')
assert_eq 'export K=[REDACTED] suite' "$redige" "expurge la valeur de clé"

intact=$(prefilter_redact 'git show a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0')
assert_eq 'git show a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0' "$intact" \
  "laisse un SHA git intact"

finish
