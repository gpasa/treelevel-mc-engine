# Protocole d'échange

`MCEngineProtocol.swift` est copié à l'identique dans TreeLevel (`Sources/FeynCore/Events/MCEngine.swift`) et
dans le moteur (`Sources/treelevel-tools/`). Il décrit le dossier de travail — `job.json`, `events.lhe`,
`status.json`, `engine.log`, `events.hepmc` — et les structures correspondantes.

Ce fichier est sous licence MIT : les deux programmes, distribués séparément et sous des licences différentes,
doivent pouvoir le lire. La copie du moteur n'a pas la fonction `readEvents`, qui dépend de la bibliothèque de
TreeLevel.

`protocolVersion` est incrémenté quand le format change d'une façon qu'un ancien moteur ne saurait pas lire ;
le moteur refuse alors le travail avec un message clair.
