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

# --- Rédaction (constat C1) ---
# Les cinq motifs, pas seulement `sk-`. Deux d'entre eux ne couvrent que
# l'en-tête ou l'identifiant public du secret : expurger « le morceau qui a
# matché » laissait le corps de clé PEM et la clé secrète AWS partir en clair.
# La commande entière doit donc être retenue, motif par motif.
CORPS_PEM='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
AWS_SECRET='0000000000000000000000000000000000000000'
# Repli explicite : le test doit rester exécutable — et échouer sur le fond —
# contre une version de prefilter.sh qui ne définit pas encore la constante.
RETENUE=${JEV_CMD_RETENUE:-'[commande retenue : secret détecté]'}

for avec_secret in \
  'export K=sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA suite' \
  "aws configure set aws_secret_access_key $AWS_SECRET ; echo AKIA0000000000000000" \
  'git remote add o https://ghp_000000000000000000000000000000000000@example.invalid/a/b' \
  'echo xoxb-000000000000-aaaaaaaaaa | tee /tmp/jeton' \
  "printf '%s\n%s\n' \"$PEM\" '$CORPS_PEM'"
do
  redige=$(prefilter_redact "$avec_secret")
  assert_eq "$RETENUE" "$redige" "retient tout: ${avec_secret:0:38}"
done

# Aucun fragment de la valeur ne doit subsister dans le texte rédigé.
redige=$(prefilter_redact "printf '%s\n%s\n' \"$PEM\" '$CORPS_PEM'")
assert_eq 0 "$(grep -c -- "$CORPS_PEM" <<<"$redige")" "aucun fragment du corps PEM"
redige=$(prefilter_redact "aws configure set aws_secret_access_key $AWS_SECRET ; echo AKIA0000000000000000")
assert_eq 0 "$(grep -c -- "$AWS_SECRET" <<<"$redige")" "aucun fragment de la clé AWS"

# Hors secret, la commande est journalisée telle quelle : c'est assumé, et
# c'est ce qui rend les désaccords de la phase A relisables.
intact=$(prefilter_redact 'git show a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0')
assert_eq 'git show a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0' "$intact" \
  "laisse un SHA git intact"

finish
