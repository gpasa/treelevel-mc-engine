# L'environnement des générateurs, là où un shell de connexion le lira.
#
# Le moteur interroge Herwig et Sherpa par « bash -lc » — ce qu'il faut sous WSL, où l'utilisateur pose son
# PATH dans ~/.bashrc. Mais /etc/profile réécrit PATH de zéro, et le ENV du Dockerfile n'y survit pas :
# /opt/treelevel-tools/bin disparaissait, et « capabilities » ne voyait que passthrough alors que
# « Herwig --version » répondait parfaitement.
export PATH=/opt/treelevel-tools/bin:$PATH
export LD_LIBRARY_PATH=/opt/treelevel-tools/lib:/opt/treelevel-tools/lib/ThePEG
export HERWIGPATH=/opt/treelevel-tools/share/Herwig
export SHERPA_INCLUDE_PATH=/opt/treelevel-tools/include/SHERPA-MC
export SHERPA_SHARE_PATH=/opt/treelevel-tools/share/SHERPA-MC
