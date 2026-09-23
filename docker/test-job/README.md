# Un travail d'essai

Deux cents événements e⁻e⁺ → b b̄ à 200 GeV écrits par TreeLevel (σ = 3,11399 pb), et le `job.json` qui demande
à Herwig de les gerber. De quoi vérifier une image en une commande :

```bash
docker run --rm -v "$PWD:/job" ghcr.io/gpasa/treelevel-mc-engine:0.2.0 run /job
cat status.json
```

`state` doit passer à `finished`, `eventsWritten` à 200, et `crossSection` rester 3.11399 — le générateur gerbe
et hadronise, il ne recalcule pas la section efficace. `events.hepmc` apparaît à côté ; il se relit avec

```bash
feyn analyze events.hepmc
```

Pour essayer Sherpa plutôt que Herwig, il faut lui décrire le processus : il calcule son élément de matrice
lui-même et ne lit pas les événements (voir `hardProcess` dans le protocole).

Le dossier se salit à l'usage (`status.json`, `engine.log`, `events.hepmc`, les fichiers du générateur) ; seuls
`job.json` et `events.lhe` sont versionnés.
