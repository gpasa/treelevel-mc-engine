# Un travail d'essai pour Sherpa

Sherpa ne lit pas les événements de TreeLevel : il calcule lui-même son élément de matrice. On lui décrit donc
le processus — c'est `hardProcess`, et il n'y a pas de `events.lhe` ici.

```bash
docker run --rm -v "$PWD:/job" ghcr.io/gpasa/treelevel-tools:0.2.0 run /job
cat status.json
```

`state` doit passer à `finished` et `eventsWritten` à 50. La section efficace, elle, est **calculée par
Sherpa** et non reprise d'un fichier : autour de 19 pb pour e⁻e⁺ → b b̄ à 200 GeV, avec son incertitude.

Ce second essai existe parce que le premier ne l'aurait jamais trouvé : `docker/test-job` n'exerce que Herwig,
et il a fallu une exécution de Sherpa pour découvrir que `libzip4` manquait dans l'image.

Le dossier se salit à l'usage ; seul `job.json` est versionné.
