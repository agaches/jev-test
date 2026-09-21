# jev-guard

Hook `PreToolUse` pour Claude Code qui délègue le jugement de sécurité à Jev
(TypeSafe AI), avec pré-filtre anti-exfiltration local et repli sur les
expressions régulières historiques.

- Spec : `docs/superpowers/specs/2026-09-18-jev-security-hooks-design.md`
- Plan : `docs/superpowers/plans/2026-09-18-jev-guard.md`

## Installation

```bash
export TYPESAFE_API_KEY="votre-clé"   # console.typesafe.ai
./install.sh
```

L'installation met le hook en **mode ombre** : Jev est interrogé et journalisé,
mais les expressions régulières restent seules décisionnaires. Aucun verdict de
Jev ne bloque quoi que ce soit tant que la phase A n'est pas validée.

`install.sh` est idempotent : le relancer remplace l'enregistrement existant au
lieu d'en ajouter un second. Chaque exécution laisse une sauvegarde horodatée
de `settings.json` à côté de celui-ci, et n'écrase jamais une sauvegarde
existante.

## Ce qui change dès le mode ombre

Le mode ombre neutralise Jev, pas la couche locale. Celle-ci est un **plancher**
repris des deux anciens hooks, et elle durcit deux comportements dès
l'installation :

- `rm -r`, `rmdir` et `unlink` produisent une **demande de confirmation**
  (`rm -rf node_modules` comprise), là où l'ancien hook affichait un
  avertissement et laissait passer ;
- une zone autorisée couvre désormais un **segment de chemin entier**. Avec
  `~/dev/proj` autorisé, le répertoire frère `~/dev/proj-notes` est bloqué,
  là où l'ancien hook comparait des préfixes nus et l'autorisait.

Ces deux points sont assumés. Ils ne dépendent ni de Jev, ni du réseau, ni de
`JEV_GUARD_MODE`.

## Vie privée

Le hook écrit un journal en clair dans `~/.claude/logs/jev-guard.jsonl`
(surchargeable par `JEV_GUARD_LOG`). Ce fichier contient, une ligne JSON par
décision :

- la **commande Bash ou le chemin de fichier en clair** (`cmd_redacted`), son
  empreinte sha256, l'outil, l'horodatage, le verdict, le verdict regex, les
  scores renvoyés par Jev et la latence ;
- **sauf** lorsqu'une valeur de secret est reconnue par le pré-filtre : la
  commande est alors entièrement retenue derrière
  `[commande retenue : secret détecté]`, et seuls subsistent l'empreinte et le
  nom du motif détecté.

La commande en clair est indispensable à la phase A : sans elle, les désaccords
du critère 2 ne sont pas relisables. C'est un compromis, pas un oubli.

Ce fichier **n'a ni rotation ni plafond de taille**. Il croît tant que le hook
tourne. Le purger :

```bash
: > ~/.claude/logs/jev-guard.jsonl      # vider
rm -f ~/.claude/logs/jev-guard.jsonl    # supprimer
```

Le cache (`~/.cache/jev-guard/`) ne contient pas les commandes : il est indexé
par empreinte et ne stocke que les scores. Le purger : `rm -rf ~/.cache/jev-guard`.

Par ailleurs, les commandes Bash sont envoyées à l'API TypeSafe. Voir
« Périmètre » en bas de ce fichier.

## Clé d'API

Le hook lit `TYPESAFE_API_KEY` dans son environnement à chaque appel. Un
`export` lancé dans le shell d'installation ne lui survit pas : sans
persistance, jev-guard bascule en repli à chaque commande et la phase A ne
mesure rien.

Rendre la clé persistante, au choix :

- l'exporter depuis votre profil shell (`~/.zshrc`, `~/.bashrc`) ;
- la faire fournir par votre gestionnaire de secrets au démarrage du shell.

`install.sh` n'écrit jamais la clé sur disque, ni dans `settings.json` ni
ailleurs. C'est délibéré.

## Configuration

Toutes ces variables se lisent dans l'environnement du hook, à chaque appel.

### Seuils de décision — `lib/decide.sh`

| Variable | Défaut | Effet |
|---|---|---|
| `JEV_T_SECRET` | `0.85` | au-dessus, une commande Bash est bloquée pour exposition de secret |
| `JEV_T_DESTRUCT_BLOCK` | `2.5` | score de destructivité à partir duquel on bloque, si la portée est `machine` ou `shared_remote` |
| `JEV_T_DESTRUCT_ASK` | `1.5` | score de destructivité à partir duquel on demande confirmation |
| `JEV_T_CONFIDENCE` | `0.60` | en dessous, une confiance basse escalade `allow` en `ask` |
| `JEV_T_FILE_BLOCK` | `0.80` | au-dessus, une écriture de fichier est bloquée |
| `JEV_T_FILE_ASK` | `0.50` | au-dessus, une écriture de fichier demande confirmation |

C'est ce tableau que vise le critère 6 de passage (« seuils réajustés »). Les
verdicts n'étant pas mis en cache — seuls les scores le sont — un seuil modifié
s'applique immédiatement, y compris aux entrées de cache déjà écrites.

### Cache — `lib/cache.sh`

| Variable | Défaut | Effet |
|---|---|---|
| `JEV_GUARD_CACHE_DIR` | `${XDG_CACHE_HOME:-~/.cache}/jev-guard` | répertoire des scores mémorisés |
| `JEV_CACHE_TTL` | `604800` (7 jours) | durée de vie d'une entrée, en secondes |

### Appel à Jev — `lib/jev-client.sh`

| Variable | Défaut | Effet |
|---|---|---|
| `TYPESAFE_API_KEY` | — | clé d'API ; absente, chaque appel part en repli |
| `JEV_GUARD_ENDPOINT` | `https://api.typesafe.ai/v1/systemone` | point d'entrée de l'API |
| `JEV_GUARD_MODEL` | `jev-latest` | modèle interrogé |
| `JEV_GUARD_TIMEOUT_MS` | `1500` | délai d'expiration de l'appel, en millisecondes ; une valeur non numérique ou nulle retombe sur 1500 |
| `JEV_GUARD_CURL` | `curl` | binaire client HTTP ; sert aux tests, jamais en production |

### Hook — `hooks/jev-guard.sh`, `lib/log.sh`, `lib/deterministic.sh`

| Variable | Défaut | Effet |
|---|---|---|
| `JEV_GUARD_MODE` | `shadow` | `shadow` : Jev observé, regex décisionnaires. `active` : Jev décide |
| `JEV_GUARD_DISABLE` | vide | non vide : Jev n'est jamais appelé, les étages locaux restent actifs |
| `JEV_GUARD_LOG` | `~/.claude/logs/jev-guard.jsonl` | fichier de journal |
| `CLAUDE_PROJECT_DIR` | `$PWD` | zone d'écriture autorisée principale |
| `ALLOWED_PATHS` | vide | zones d'écriture supplémentaires, séparées par `:` |

### Analyse — `tools/analyze-shadow-log.sh`

| Variable | Défaut | Effet |
|---|---|---|
| `JEV_ANALYSE_SEUIL_REJET_PCT` | `5` | part de lignes illisibles au-delà de laquelle le rapport est jugé non représentatif et le script sort en 2 |

## Phase A

Utiliser Claude Code normalement, puis :

```bash
./tools/analyze-shadow-log.sh
```

Les six critères de passage figurent dans le rapport, sous la matrice de
désaccords. Le taux de repli est calculé sur les seules décisions réellement
soumises à Jev, et le compte de décisions du critère 1 sur les seules commandes
`Bash`. Les compteurs de désaccords et la liste à relire ne retiennent que les
décisions où Jev a pesé (sources `jev` et `cache`) : les blocages locaux en
sont exclus.

Le script annonce le nombre de lignes illisibles rencontrées et sort en 2
au-delà de `JEV_ANALYSE_SEUIL_REJET_PCT`.

### Ce que 44 appels réels ont déjà montré

Mesures relevées contre le modèle `jev-1.13.0`, hors dépôt, avant déploiement.
Elles ne dispensent pas de la phase A ; elles en fixent le point de départ.

- **Contrat de réponse vérifié** : les cinq champs lus par `lib/decide.sh` sont
  présents et du type attendu. `secret_exposure.confidence` n'existe pas dans
  la réponse ; `decide.sh` ne le lit pas.
- **Latence**, sur 14 appels : médiane 628 ms, p95 690 ms, maximum 954 ms. Le
  critère 4 (`p95 < 800 ms`) passe, et le maximum observé garde 546 ms de marge
  sur le défaut `JEV_GUARD_TIMEOUT_MS=1500`.
- **Porte de confiance calibrée sur ces appels**, pas sur une hypothèse. Dans sa
  version d'origine, elle interrompait 15 à 30 % du trafic ordinaire sur des
  commandes sans effet, par une confiance faible sur la portée. Elle ne seuille
  plus que la confiance sur la destructivité ; voir le commentaire de la règle 4
  dans `lib/decide.sh`.
- **Le verdict n'est pas déterministe au voisinage d'un seuil** : la même
  commande peut donner `ask` puis `allow` d'un appel à l'autre, et le cache fige
  le premier obtenu pour la durée du TTL. À garder en tête en relisant les
  désaccords du critère 2.

Une fois tous remplis et les désaccords relus, passer en mode actif :

```bash
export JEV_GUARD_MODE=active
```

Retour arrière : remettre `JEV_GUARD_MODE=shadow`, ou `JEV_GUARD_DISABLE=1` pour
court-circuiter Jev entièrement.

## Mode dégradé

Sans `jq` dans le `PATH`, le hook ne sait ni lire proprement son entrée ni
écrire un JSON de décision. Il applique alors le plancher local seul — pré-filtre,
confinement de chemin, expressions régulières — et bloque en code 2 ce que ce
plancher bloque. Un verdict `ask` n'étant pas exprimable dans ce mode, il laisse
passer. Rien n'est journalisé.

Sans `grep`, en revanche, le hook **bloque tout** ce qui entre dans son
périmètre, jq présent ou non. Cinq des six règles du plancher passent par
`grep` : sans lui, elles ne s'évaluent pas et le plancher autoriserait ce qu'il
est censé refuser. Un contrôle qui ne peut pas juger n'autorise pas. Rétablir
`grep` dans le `PATH` lève le blocage.

## Tests

```bash
./tests/run-tests.sh
```

Aucun test ne touche le réseau. Aucun test n'écrit hors d'un `mktemp -d`.

## Périmètre

Les commandes Bash sont envoyées à l'API TypeSafe. Arbitrage consigné en spec
§13 R1 : accepté dans un cadre POC, hors code client. Utiliser
`JEV_GUARD_DISABLE=1` pour couper par projet.
