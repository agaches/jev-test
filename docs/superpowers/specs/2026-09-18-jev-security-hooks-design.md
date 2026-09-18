# Design : hooks de sécurité Claude Code adossés à Jev

Date : 2026-09-18
Statut : validé pour implémentation
Portée : remplacement des hooks `PreToolUse` de sécurité par une décision typée Jev, avec repli local.

## 1. Contexte

La configuration Claude Code actuelle (`~/.claude`) enregistre deux hooks `PreToolUse`
de sécurité :

| Hook | Rôle actuel | Lignes |
|---|---|---|
| `dangerous-actions-blocker.sh` | motifs de commandes dangereuses, force-push, publication de paquet, motifs de secrets, fichiers protégés, confinement de chemin | 142 |
| `security-check.sh` | motifs de secrets, formats de clés d'API | 46 |

Les deux reposent sur des correspondances littérales de sous-chaînes et quelques
expressions régulières. Cette approche produit deux classes d'erreurs constatées à la
lecture du code.

**Faux positifs.** `security-check.sh:39` bloque toute commande contenant
`[a-f0-9]{32,}`. Un SHA de commit git complet fait 40 caractères hexadécimaux : ce
hook bloque donc par construction `git show <sha>`, `git cherry-pick <sha>` et tout
checkout par SHA complet. Même mécanique pour le motif `token=`, qui bloque une URL
publique contenant `?token=`.

**Faux négatifs.** La liste `DANGEROUS_PATTERNS` (`dangerous-actions-blocker.sh:21-35`)
est une correspondance littérale. `rm -rf "$PROJECT/.."`, `find . -delete`,
`git reset --hard`, ou toute construction passant par une variable ne sont pas vus.

**Duplication.** `security-check.sh:13-29` et `dangerous-actions-blocker.sh:57-66`
cherchent la même famille de motifs de secrets. Deux process sont exécutés pour une
décision dupliquée, à chaque commande Bash.

Jev (TypeSafe AI) est un modèle produisant des décisions typées et calibrées à faible
latence. Il correspond à la forme du problème : un jugement contextuel sur une chaîne,
avec une réponse dans un espace fini défini à l'avance et une probabilité associée.

## 2. Objectifs

1. Supprimer les faux positifs bloquants sur les identifiants git et les valeurs
   hexadécimales anodines.
2. Détecter les commandes destructrices que la correspondance littérale ne voit pas.
3. Ne jamais dégrader la protection en dessous du comportement actuel, y compris hors
   ligne ou hors quota.
4. Rester sous un budget de latence compatible avec un hook exécuté à chaque appel
   d'outil.
5. Produire des mesures permettant de décider, sur données réelles, si Jev fait mieux
   que les expressions régulières.

## 3. Non-objectifs

- Remplacer le système de permissions natif de Claude Code.
- Couvrir d'autres outils que `Bash`, `Edit` et `Write`.
- Modifier `rtk-rewrite.sh`, `rtk-auto-wrapper.sh` ou les hooks `peon-ping`.
- Traiter les autres cas d'usage Jev identifiés lors de l'analyse (compaction de
  contexte, skills à fort volume, porte de compression flow-lean). Ils feront l'objet
  de specs distinctes.

## 4. Décisions actées

| Réf | Décision | Raison |
|---|---|---|
| D1 | Fusionner les deux hooks en un seul `jev-guard.sh` | Supprime la duplication et ramène la décision à un seul appel réseau |
| D2 | Runtime shell : `curl` + `jq` | ~5 ms de démarrage contre 150-300 ms pour un interpréteur Python, sur un hook exécuté à chaque outil |
| D3 | Jev primaire, expressions régulières locales en repli dégradé | L'utilisateur conserve un plancher hors ligne sans dépendre de la disponibilité de l'API |
| D4 | Code hébergé dans un nouveau dépôt `jev-test` | Terrain d'essai isolé ; promotion vers `~/.claude` seulement après validation |
| D5 | Le seuillage reste en shell, pas dans le modèle | Conforme au modèle d'usage de Jev : le modèle produit des probabilités, le code produit la décision |
| D6 | Déploiement en deux phases, mode ombre puis mode actif | Un contrôle de sécurité ne bascule pas sur un classifieur dont le taux d'erreur n'a pas été mesuré sur le trafic réel |
| D7 | Pré-filtre local anti-exfiltration avant tout appel réseau | Voir §7 : envoyer à un tiers une commande contenant un secret en clair est le risque que le hook est censé prévenir |

## 5. Architecture

```
PreToolUse (Bash | Edit | Write)
        │
        ▼
  ┌─────────────────┐
  │  jev-guard.sh   │
  └─────────────────┘
        │
        ├─ 1. Vérifications déterministes   ─── bloque ──→ verdict local
        │     (confinement de chemin,
        │      liste de fichiers protégés)
        │
        ├─ 2. Pré-filtre anti-exfiltration  ─── match ───→ block, SANS appel réseau
        │     (valeurs de secrets évidentes)
        │
        ├─ 3. Cache de verdicts             ─── hit ─────→ verdict mémorisé
        │
        ├─ 4. Appel Jev (timeout 1,5 s)     ─── ok ──────→ seuillage → verdict
        │                                    └─ échec ──┐
        │                                                │
        └─ 5. Repli : regex locales actuelles ◄──────────┘
                     │
                     ▼
              journalisation JSONL
```

### Arborescence du dépôt

```
jev-test/
├── README.md
├── docs/superpowers/specs/2026-09-18-jev-security-hooks-design.md
├── hooks/
│   └── jev-guard.sh              # point d'entrée PreToolUse
├── lib/
│   ├── jev-client.sh             # construction du payload, appel curl, parsing jq
│   ├── deterministic.sh          # confinement de chemin, fichiers protégés
│   ├── prefilter.sh              # pré-filtre anti-exfiltration
│   ├── fallback.sh               # regex actuelles, mode dégradé
│   ├── cache.sh                  # cache de verdicts sur disque
│   └── log.sh                    # journal JSONL
├── tests/
│   ├── fixtures/commands.tsv     # corpus commande → verdict attendu
│   └── run-tests.sh
└── tools/
    └── analyze-shadow-log.sh     # exploitation du journal de phase A
```

## 6. Partage entre Jev et code déterministe

Jev n'absorbe pas les contrôles que le code fait déjà correctement.

**Restent en code déterministe :**

- Le confinement de chemin (`dangerous-actions-blocker.sh:106-130`) : une comparaison
  de préfixe exacte, correcte et gratuite. La confier à un modèle probabiliste
  n'ajouterait que du risque.
- La liste de fichiers protégés par nom de base exact : correspondance exacte, coût nul.
  Elle sert de plancher ; Jev couvre en plus les variantes absentes de la liste.

**Confiés à Jev :**

- Le caractère destructeur d'une commande shell et sa portée.
- La distinction entre une *valeur* de secret en clair et la simple présence du mot
  `token`, `secret` ou `password`.
- Le caractère sensible d'un chemin de fichier absent de la liste exacte
  (`.env.staging`, `config/secrets/prod.key`, `~/.aws/credentials`).

## 7. Pré-filtre anti-exfiltration

Ce point n'apparaissait pas dans le cadrage initial et modifie l'ordonnancement retenu
en D3.

Le hook a pour mission de détecter les secrets en clair dans les commandes. Si sa
première action est d'envoyer la commande à une API tierce, alors sur exactement le cas
qu'il doit traiter, il exfiltre le secret vers TypeSafe avant de le bloquer. Le contrôle
provoquerait l'incident qu'il prévient.

Correctif : avant tout appel réseau, un pré-filtre local applique un jeu restreint de
motifs de **valeurs** de secrets à forte spécificité :

```
sk-[A-Za-z0-9]{20,}          clés de type OpenAI
AKIA[0-9A-Z]{16}             identifiants AWS
ghp_[A-Za-z0-9]{36}          jetons GitHub
xox[baprs]-[A-Za-z0-9-]{10,} jetons Slack
-----BEGIN [A-Z ]*PRIVATE KEY-----
```

En cas de correspondance : blocage immédiat, aucun appel réseau, journalisation du
verdict avec la valeur **expurgée**.

Ce jeu est volontairement plus étroit que la liste actuelle. Il ne cible que des formats
de valeurs non ambigus, jamais des noms de variables comme `token=`, ce qui le rend
insensible au faux positif décrit en §1.

## 8. Contrat Jev

### 8.1 Format de requête

Endpoint vérifié : `POST https://api.typesafe.ai/v1/systemone`
Authentification : `TYPESAFE_API_KEY` en variable d'environnement.
Alias de modèle : `jev-latest`.

> **À vérifier avant implémentation.** La forme exacte du corps JSON sur le fil n'a pas
> été confirmée dans cette session : elle a été déduite des exemples SDK Python et
> JavaScript, pas lue depuis la référence HTTP. La première tâche d'implémentation est
> de confirmer le schéma exact contre `https://docs.typesafe.ai/api` et d'ajuster
> `lib/jev-client.sh` en conséquence. Le reste du design ne dépend pas de ce détail.

Forme attendue :

```json
{
  "model": "jev-latest",
  "state": {
    "tool": "Bash",
    "command": "<commande>",
    "cwd": "<répertoire courant>",
    "in_git_repo": true
  },
  "questions": {
    "destructiveness": { "type": "score",  "instructions": "...", "criteria": [...] },
    "secret_exposure": { "type": "noul",   "instructions": "..." },
    "blast_radius":    { "type": "choice", "instructions": "...", "criteria": {...} }
  }
}
```

Les trois questions partent dans un appel unique : l'API les évalue indépendamment,
ce qui évite trois allers-retours réseau.

### 8.2 Questions typées — outil `Bash`

**`destructiveness`** (`Score`, rubrique ordonnée, indices 0 à 3)

```
0  Aucune modification d'état : lecture, inspection, affichage, recherche.
1  Modification réversible sans effort : création de fichier, écriture dans un
   fichier suivi par git, installation de dépendance locale.
2  Perte possible de travail local non sauvegardé : reset, checkout destructif,
   stash drop, suppression de fichiers non suivis, réécriture d'historique local.
3  Destruction irréversible ou effet hors de la machine : suppression récursive
   large, force-push, suppression de branche distante, drop de base, publication
   de paquet, écriture sur un périphérique bloc.
```

La valeur retournée est pondérée par les probabilités et peut tomber entre deux
niveaux ; les seuils du §8.3 en tiennent compte.

**`secret_exposure`** (`Noul`)

> La commande contient-elle la **valeur** d'un secret en clair (clé d'API, jeton,
> mot de passe, clé privée) ? Répondre non si la commande ne fait que nommer une
> variable d'environnement, lire un secret depuis un fichier ou un gestionnaire de
> secrets, ou contenir un identifiant de commit, un hachage ou un UUID.

La seconde phrase est ce qui corrige le faux positif sur les SHA git : l'instruction
exclut explicitement la classe d'objets que la regex actuelle confond avec une clé.

**`blast_radius`** (`Choice`)

```
cwd            L'effet reste dans le répertoire de travail courant.
repo           L'effet touche le dépôt local au-delà du répertoire courant.
machine        L'effet touche la machine hors du dépôt : système, paquets globaux,
               répertoire personnel, configuration utilisateur.
shared_remote  L'effet est visible par d'autres : dépôt distant, service déployé,
               base de données partagée, registre de paquets.
```

### 8.3 Seuillage

Le seuillage est en shell. Le modèle fournit des nombres, le code décide.

Les règles sont évaluées dans l'ordre, la première qui s'applique l'emporte :

```
1. secret_exposure > 0.85                                            → block
2. destructiveness >= 2.5 et blast_radius ∈ {machine, shared_remote} → block
3. destructiveness >= 1.5                                            → ask
4. confidence(destructiveness) < 0.60 ou confidence(blast_radius) < 0.60 → ask
5. sinon                                                             → allow
```

La règle 4 est une porte de confiance : elle ne peut produire qu'une escalade de
`allow` vers `ask`. Comme elle est évaluée après les règles 1 à 3, elle ne peut jamais
annuler un blocage ni adoucir un verdict déjà prononcé. Une décision peu assurée
demande confirmation plutôt que d'autoriser silencieusement.

Ces valeurs sont des points de départ. Elles seront recalibrées en fin de phase A sur
les données réelles (§10).

### 8.4 Questions typées — outils `Edit` et `Write`

Les contrôles déterministes s'exécutent d'abord et inchangés. Si le chemin passe, une
question unique part vers Jev :

**`sensitive_file`** (`Noul`)

> Ce chemin désigne-t-il un fichier contenant des secrets, des identifiants, une clé
> privée ou une configuration de production sensible ?

Seuil : `> 0.80` → block, `> 0.50` → ask, sinon allow.

Le cache est indexé par chemin, ce qui ramène le coût à un appel par fichier distinct
plutôt qu'un appel par édition. Un même fichier édité vingt fois dans une session ne
déclenche qu'un seul appel.

## 9. Repli, cache et journal

### Repli

Déclencheurs du mode dégradé : `TYPESAFE_API_KEY` absente, timeout `curl` dépassé,
code HTTP non 2xx, réponse JSON non parsable, `jq` ou `curl` indisponible.

En mode dégradé, `lib/fallback.sh` applique les expressions régulières actuelles,
reprises telles quelles depuis les deux hooks existants. Le comportement est alors
strictement celui d'aujourd'hui, faux positifs compris. C'est un plancher assumé, pas
une régression : l'utilisateur ne se retrouve jamais moins protégé qu'avant ce chantier.

Chaque bascule en mode dégradé est journalisée avec sa cause.

### Cache

- Clé : `sha256(tool + "\x00" + command_ou_path + "\x00" + cwd)`.
- Emplacement : `${JEV_GUARD_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/jev-guard}`.
- Durée de vie : 7 jours.
- Contenu : verdict, probabilités, horodatage. Jamais la commande en clair.

Le cache n'est consulté qu'après le pré-filtre anti-exfiltration, pour qu'un secret ne
puisse jamais être servi depuis le cache sans repasser par le blocage.

### Journal

Un enregistrement JSONL par décision, dans
`${JEV_GUARD_LOG:-$HOME/.claude/logs/jev-guard.jsonl}` :

```json
{
  "ts": "2026-09-18T14:02:11Z",
  "tool": "Bash",
  "cmd_sha256": "…",
  "cmd_redacted": "git show a1b2c3…",
  "source": "jev",
  "verdict": "allow",
  "regex_verdict": "block",
  "agreed": false,
  "scores": { "destructiveness": 0.2, "secret_exposure": 0.01, "blast_radius": "cwd" },
  "confidence": 0.94,
  "latency_ms": 118
}
```

`cmd_redacted` passe par l'expurgation du pré-filtre avant écriture. Le journal ne doit
jamais devenir lui-même une fuite de secrets.

## 10. Déploiement en deux phases

### Phase A — mode ombre

`JEV_GUARD_MODE=shadow`. Jev est interrogé, les verdicts sont journalisés, **aucun
blocage n'est prononcé par Jev**. Les expressions régulières actuelles restent seules
décisionnaires. Chaque désaccord entre Jev et la regex est enregistré.

`tools/analyze-shadow-log.sh` produit la matrice de confusion et la liste des
désaccords classés par type.

**Critères de passage en phase B, tous requis :**

1. Au moins 200 décisions `Bash` journalisées sur du trafic réel.
2. Tous les désaccords de classe bloquante relus manuellement.
3. Aucun cas où Jev autorise une commande que la regex bloque à juste titre.
4. Latence au 95e centile sous 800 ms.
5. Taux de bascule en mode dégradé sous 5 %.
6. Seuils du §8.3 réajustés sur les données observées.

### Phase B — mode actif

`JEV_GUARD_MODE=active`. Jev devient décisionnaire selon le §8.3, la regex passe en
repli. Retour arrière par une seule variable d'environnement.

## 11. Configuration

| Variable | Défaut | Rôle |
|---|---|---|
| `TYPESAFE_API_KEY` | — | Clé d'API. Absente : mode dégradé permanent. |
| `JEV_GUARD_MODE` | `shadow` | `shadow` ou `active`. |
| `JEV_GUARD_TIMEOUT_MS` | `1500` | Timeout `curl`. |
| `JEV_GUARD_MODEL` | `jev-latest` | Alias de modèle. |
| `JEV_GUARD_LOG` | `$HOME/.claude/logs/jev-guard.jsonl` | Journal. |
| `JEV_GUARD_CACHE_DIR` | `$XDG_CACHE_HOME/jev-guard` | Cache. |
| `JEV_GUARD_DISABLE` | non défini | Si défini, court-circuite Jev et force le repli. |

Le défaut `shadow` est délibéré : une installation qui oublie de configurer le mode
n'active pas un blocage non mesuré.

## 12. Tests

`tests/run-tests.sh` exécute un corpus `tests/fixtures/commands.tsv` de paires
commande → verdict attendu, avec l'appel réseau simulé par des réponses Jev figées.
Aucun test ne touche l'API réelle.

Le corpus doit contenir au minimum :

**Faux positifs actuels, attendus en `allow` :**
`git show a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0`, `git cherry-pick <sha40>`,
`curl "https://api.example.com/v1/data?token=public"`, `md5sum fichier.txt`

**Faux négatifs actuels, attendus en `ask` ou `block` :**
`find . -delete`, `git reset --hard origin/main`, `rm -rf "$PROJECT/.."`,
`git push --force origin feature`, `kubectl delete namespace prod`

**Comportements à préserver :**
`rm -rf /`, `dd if=/dev/zero of=/dev/sda`, `npm publish`,
`git push --force origin main`, édition de `.env`

**Pré-filtre, attendus en `block` sans appel réseau :**
`export OPENAI_API_KEY=sk-proj-XXXXXXXXXXXXXXXXXXXXXXXX`,
`aws configure set aws_access_key_id AKIAXXXXXXXXXXXXXXXX`

Un test dédié vérifie qu'aucune requête réseau n'est émise quand le pré-filtre
déclenche. C'est la garantie centrale du §7 ; elle doit être vérifiée par un test, pas
par relecture.

**Modes de défaillance :** clé absente, timeout, HTTP 500, JSON malformé, quota dépassé.
Chacun doit produire le verdict de repli et un enregistrement de journal.

## 13. Risques

| Réf | Risque | Traitement |
|---|---|---|
| R1 | Toute commande Bash part vers un tiers. En contexte professionnel, les commandes contiennent des noms d'hôtes, de projets et de bases internes. | **Arbitré le 2026-09-18 : accepté dans le cadre d'un POC.** Le périmètre d'usage est la validation technique, pas le code client. `JEV_GUARD_DISABLE` permet une coupure par projet. Un passage en usage courant sur du code client rouvrirait cet arbitrage. Levée structurelle attendue : un Jev à poids ouverts exécuté localement ferme ce risque au lieu de le contenir (§14). |
| R2 | Le pré-filtre ne couvre que des formats de secrets connus. Un secret maison part vers Jev. | Périmètre assumé. Le jeu de motifs est extensible ; §7 documente le critère d'ajout. |
| R3 | Une panne TypeSafe ramène silencieusement au comportement actuel. | Le taux de bascule est journalisé et fait partie des critères de phase B. |
| R4 | Les seuils du §8.3 ne sont pas calibrés sur des données réelles. | C'est précisément l'objet de la phase A. Ils ne doivent pas être considérés comme validés avant. |
| R5 | Jev est en accès anticipé ; limites, tarifs et alias de modèle peuvent changer. | Alias de modèle et seuils externalisés en configuration, jamais codés en dur. |
| R6 | Le journal pourrait contenir des secrets. | `cmd_redacted` passe par l'expurgation avant écriture, vérifié par test. |

## 14. Suites hors périmètre

**Cadre de travail de cette liste.** Ce qu'on cherche ici, c'est identifier des
cas d'usage pour ce type de modèle : décision typée, calibrée, à faible latence.
La question de la sensibilité de la donnée n'est pas rouverte à chaque entrée de
la liste ; elle est posée une fois pour toutes en R1 et reste une contrainte
connue. Un nouveau cas d'usage n'a donc pas à re-plaider l'arbitrage, seulement à
signaler en une ligne ce qu'il change au périmètre de données exposé, quand il le
change (le routage de modèle du §14.1 le fait au point 3 : il voit tous les
prompts, pas seulement des commandes shell).

**Levée structurelle attendue.** Un Jev à poids ouverts, exécutable localement,
supprimerait le problème à la racine plutôt que de le contenir : plus rien ne
sort de la machine, R1 tombe, le pré-filtre du §7 redevient une précaution et non
une nécessité, et le budget de latence se réduit à un appel local. Ce serait
aussi un gain de performance de premier ordre sur les cas à fort volume de cette
liste, où le coût par appel réseau est ce qui décide de la viabilité. Cette
hypothèse conditionne l'ordre de priorité ci-dessous : les cas que l'exposition
de données freine aujourd'hui deviendraient les plus rentables le jour où elle
disparaît.

Les autres cibles Jev identifiées lors de l'analyse, par ordre de retour attendu :
compaction de contexte, skills à fort volume (`liza-logs`, `dpe-search`, `rech-immo`,
`document-organizer`), porte de compression flow-lean, triage de revue de code,
routage de modèle (§14.1). Chacune fera l'objet d'une spec propre. La couche
`lib/jev-client.sh` construite ici est prévue pour être réutilisée telle quelle.

### 14.1 Routage de modèle — Jev en aiguilleur

Ajouté le 2026-09-18. Non cadré, pas de spec à ce jour.

**Idée.** Utiliser Jev comme routeur automatique en amont de l'appel au modèle :
classer le prompt entrant, puis choisir le modèle et le budget de raisonnement
adaptés plutôt que de servir le plus gros modèle à chaque tour. C'est la forme
d'une brique type RouteLLM, avec la décision typée de Jev à la place d'un
classifieur maison à entraîner.

**Pourquoi Jev colle à ce problème.** Même forme que le hook de sécurité : un
jugement contextuel sur une chaîne, une réponse dans un espace fini connu
d'avance, une probabilité associée, et un budget de latence serré parce que la
décision se prend avant chaque tour. Le seuillage resterait en code, jamais dans
le modèle (D5).

**Questions typées pressenties**, à confirmer au cadrage :

| Question | Type | Rôle |
|---|---|---|
| `task_kind` | `choice` | `code`, `debug`, `analyse`, `rédaction`, `conversation`, `outillage` |
| `reasoning_needed` | `score` | rubrique ordonnée : réponse directe → raisonnement long |
| `context_breadth` | `choice` | fichier unique, module, dépôt entier |
| `stakes` | `noul` | une erreur coûte-t-elle cher (production, données, argent) ? |

La table de routage `(task_kind, reasoning_needed, stakes) → modèle + budget`
reste en configuration, externalisée comme les seuils du §8.3 (risque R5).

**Points durs à trancher au cadrage.**

1. **Le routeur paie sa propre latence à chaque tour.** Le hook de sécurité peut
   se cacher derrière un cache indexé par commande ; un prompt en langage naturel
   se répète beaucoup moins. Le gain de coût doit couvrir l'appel de routage.
2. **Un mauvais aiguillage vers le bas est silencieux.** Contrairement à un
   blocage de sécurité, une réponse produite par un modèle sous-dimensionné ne
   lève aucune alerte. Le déploiement en deux phases du §10 s'applique tel quel :
   mode ombre d'abord, désaccords journalisés, bascule seulement sur données.
3. **Le routeur voit tous les prompts**, donc le risque R1 est plus large ici
   que pour les commandes Bash. Un pré-filtre analogue au §7 serait à repenser :
   les motifs de valeurs de secrets ne suffisent pas à couvrir du texte libre.
4. **Périmètre d'application à définir** : aiguillage entre modèles d'un même
   fournisseur, ou entre fournisseurs. Le second cas rouvre l'arbitrage R1.

Nom de code proposé par l'auteur, à ses risques : *JevFaitLeTraffic*.
