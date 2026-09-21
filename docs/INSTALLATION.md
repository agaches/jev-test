# Installation de jev-guard

Deux portées possibles. Elles ne s'excluent pas et n'ont pas les mêmes effets.

| | Portée projet | Portée globale |
|---|---|---|
| Fichier | `<projet>/.claude/settings.local.json` | `~/.claude/settings.json` |
| S'applique à | ce projet seulement | tous tes projets |
| Anciens hooks | **ils continuent de tourner** | `install.sh` les retire |
| Pose | à la main, voir plus bas | `./install.sh` |
| Bon pour | un essai cadré | la phase A réelle |

---

## Avant tout : la clé d'API

Sans elle, rien ne fonctionne comme prévu. Le hook lit `TYPESAFE_API_KEY` dans
son environnement **à chaque appel** (`lib/jev-client.sh`). Si elle est absente,
`jev_query` renvoie `cle_absente` et chaque décision part en repli : le hook se
comporte alors comme les anciennes expressions régulières, et le rapport de
phase A affiche un taux de repli de 100 %.

Un `export` lancé dans le shell d'installation ne suffit pas : il ne survit pas
à la session. La clé doit être dans ton profil shell.

```bash
# Si la clé est déjà dans ton environnement courant, la recopier sans la
# retaper — l'historique ne garde alors que le nom de la variable.
printf 'export TYPESAFE_API_KEY=%q\n' "$TYPESAFE_API_KEY" >> ~/.zshrc
```

```bash
# Sinon, éditer ~/.zshrc (ou ~/.bashrc) et y ajouter :
export TYPESAFE_API_KEY="votre-clé"        # console.typesafe.ai
```

Meilleure forme si tu as un gestionnaire de secrets : rien ne touche le disque.

```bash
export TYPESAFE_API_KEY="$(votre-gestionnaire lire typesafe/api-key)"
```

**Redémarre Claude Code après.** Le hook hérite de l'environnement du processus
Claude Code, pas de celui de ton terminal au moment où tu tapes.

`install.sh` n'écrit jamais la clé sur disque, ni dans `settings.json` ni dans
un profil. C'est délibéré : un script qui dépose un secret quelque part est un
défaut, pas une commodité. Il se contente de t'avertir si la variable manque.

Vérifier que la clé est bien vue par une nouvelle session :

```bash
echo ${TYPESAFE_API_KEY:+définie}${TYPESAFE_API_KEY:-ABSENTE}
```

---

## Portée projet

Pour essayer jev-guard sur un seul projet sans toucher à ta configuration
globale.

### Ce que tu dois savoir d'abord

**Les réglages de projet s'ajoutent aux globaux, ils ne les remplacent pas.**
Pour les hooks, tout ce qui est déclaré s'exécute. Tes hooks globaux
(`dangerous-actions-blocker.sh`, `security-check.sh`) continueront donc de
tourner, et jev-guard s'ajoutera par-dessus. Aucune clé ne permet de désactiver
un hook global depuis un projet ; `disableAllHooks` existe mais couperait aussi
tous tes autres hooks.

Conséquences concrètes :

- **La mesure de phase A fonctionne normalement.** Le journal se remplit, la
  matrice de désaccords est juste, les six critères se calculent.
- **Les faux positifs de l'ancien système restent**, puisque les anciens hooks
  décident toujours.
- **Le confort ne s'améliore pas, il baisse.** Le plancher regex de jev-guard
  est plus strict que l'ancien hook : `rm -r` sur un répertoire demande
  confirmation là où l'ancien se contentait d'un avertissement. Cette
  confirmation s'ajoute à ce que font déjà tes hooks actuels.
- **Chaque commande Bash prend environ 650 ms de plus** (latence médiane
  mesurée de l'API).

Le bénéfice du projet — moins de faux positifs — n'arrive qu'en portée globale,
quand `install.sh` retire les deux hooks remplacés.

### Pose

Créer `<projet>/.claude/settings.local.json` :

```json
{
  "env": {
    "JEV_GUARD_MODE": "shadow"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/chemin/absolu/vers/jev-test/hooks/jev-guard.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

Le chemin du hook doit être **absolu** : Claude Code n'exécute pas le hook
depuis la racine du projet.

Un `matcher` vide s'applique à tous les outils. Le hook ne traite que `Bash`,
`Edit` et `Write`, et sort immédiatement sur les autres.

Ajouter le fichier au `.gitignore` du projet :

```bash
printf '.claude/settings.local.json\n' >> .gitignore
```

Il contient un chemin absolu propre à ta machine, il n'a rien à faire dans le
dépôt. Utilise `.claude/settings.json` (versionné) seulement si toute l'équipe
a le hook au même endroit.

### Vérification

```bash
# Le JSON est valide et le hook est au bon endroit du schéma
jq -e '.hooks.PreToolUse[] | select(.matcher == "") | .hooks[]
       | select(.type == "command") | .command' .claude/settings.local.json

# Le fichier est bien ignoré par git
git check-ignore -v .claude/settings.local.json
```

Un `settings.json` invalide désactive **silencieusement** tous les réglages du
fichier. Si `jq -e` ne sort rien, rien ne marchera et personne ne te le dira.

### Prise en compte

Claude Code ne surveille que les répertoires qui contenaient déjà un fichier de
réglages au démarrage de la session. Si tu viens de créer `.claude/`, le hook
**ne sera pas chargé** avant d'avoir ouvert `/hooks` une fois, ou redémarré
Claude Code.

### Retrait

Supprime le fichier, ou juste le bloc `hooks` qu'il contient.

```bash
rm <projet>/.claude/settings.local.json
```

---

## Portée globale

C'est la configuration visée par le projet : jev-guard **remplace** les deux
hooks historiques.

```bash
export TYPESAFE_API_KEY="votre-clé"   # voir plus haut pour la persistance
./install.sh
```

L'installateur :

1. vérifie que `jq` et `curl` sont présents, et s'arrête sinon ;
2. sauvegarde `~/.claude/settings.json` sous
   `settings.json.avant-jev-guard.<horodatage>` (suffixe incrémental en cas de
   collision) ;
3. retire les entrées `dangerous-actions-blocker.sh` et `security-check.sh`,
   **conserve tous les autres hooks** (`rtk-*` et les tiens) ;
4. ajoute jev-guard, en écriture atomique : le fichier vivant n'est remplacé
   qu'une fois le résultat validé ;
5. avertit si `TYPESAFE_API_KEY` est absent de l'environnement.

Il est idempotent : deux exécutions ne laissent qu'une seule entrée jev-guard.

### Vérification

```bash
jq '.hooks.PreToolUse' ~/.claude/settings.json
```

Attendu : une entrée `jev-guard.sh`, aucune entrée
`dangerous-actions-blocker.sh` ni `security-check.sh`, tes autres hooks
intacts.

### Retour arrière

Par ordre de brutalité croissante :

```bash
export JEV_GUARD_MODE=shadow    # Jev observe, les regex décident (défaut)
export JEV_GUARD_DISABLE=1      # Jev n'est plus interrogé du tout
cp ~/.claude/settings.json.avant-jev-guard.<horodatage> ~/.claude/settings.json
```

`install.sh` affiche le chemin exact de la sauvegarde à la fin de son exécution.

---

## Répétition à blanc

Pour voir ce que l'installateur ferait sans toucher à ta vraie configuration :

```bash
essai=$(mktemp -d)
mkdir -p "$essai/.claude"
cp ~/.claude/settings.json "$essai/.claude/"
HOME="$essai" ./install.sh
jq '.hooks.PreToolUse' "$essai/.claude/settings.json"
rm -rf "$essai"
```

`mktemp -d` crée un répertoire en mode 0700 : ta configuration n'est pas
recopiée dans un répertoire lisible par tous.

---

## Après l'installation

Utiliser Claude Code normalement, puis :

```bash
./tools/analyze-shadow-log.sh
```

Le rapport donne la matrice de désaccords et l'état des six critères de passage
en mode actif. Les seuils et toutes les variables de configuration sont
documentés dans la section « Configuration » du `README.md`.

Le journal est en clair dans `~/.claude/logs/jev-guard.jsonl` : lis la section
« Vie privée » du `README.md` avant de le partager.
