# L'environnement des générateurs, là où un shell de connexion le lira.
#
# Le moteur interroge Herwig et Sherpa par « bash -lc » — ce qu'il faut sous WSL, où l'utilisateur pose son
# PATH dans ~/.bashrc. Mais /etc/profile réécrit PATH de zéro, et le ENV du Dockerfile n'y survit pas :
# /opt/treelevel-mc/bin disparaissait, et « capabilities » ne voyait que passthrough alors que
# « Herwig --version » répondait parfaitement.
export PATH=/opt/treelevel-mc/bin:$PATH
export LD_LIBRARY_PATH=/opt/treelevel-mc/lib:/opt/treelevel-mc/lib/ThePEG
export HERWIGPATH=/opt/treelevel-mc/share/Herwig
export SHERPA_INCLUDE_PATH=/opt/treelevel-mc/include/SHERPA-MC
export SHERPA_SHARE_PATH=/opt/treelevel-mc/share/SHERPA-MC
