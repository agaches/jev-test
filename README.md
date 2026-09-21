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
mais les expressions régulières restent seules décisionnaires. Rien n'est bloqué
par Jev tant que la phase A n'est pas validée.

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

## Phase A

Utiliser Claude Code normalement, puis :

```bash
./tools/analyze-shadow-log.sh
```

Les six critères de passage figurent dans le rapport, sous la matrice de
désaccords. Le taux de repli est calculé sur les seules décisions réellement
soumises à Jev, et le compte de décisions du critère 1 sur les seules commandes
`Bash`.

Une fois tous remplis et les désaccords relus, passer en mode actif :

```bash
export JEV_GUARD_MODE=active
```

Retour arrière : remettre `JEV_GUARD_MODE=shadow`, ou `JEV_GUARD_DISABLE=1` pour
court-circuiter Jev entièrement.

## Tests

```bash
./tests/run-tests.sh
```

Aucun test ne touche le réseau.

## Périmètre

Les commandes Bash sont envoyées à l'API TypeSafe. Arbitrage consigné en spec
§13 R1 : accepté dans un cadre POC, hors code client. Utiliser
`JEV_GUARD_DISABLE=1` pour couper par projet.
