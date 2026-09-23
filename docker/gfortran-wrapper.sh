#!/bin/sh
# gfortran, toujours avec -fno-range-check.
#
# Herwig embarque LoopTools, dont D0func.F écrit « parameter (nz2 = -2147483648) » : la constante déborde pour
# un gfortran moderne, qui refuse ensuite tout ce qui s'en sert. Le drapeau qu'il suggère ne peut pas passer
# par l'environnement — configure écrase FCFLAGS —, d'où cet enrobage posé devant /usr/bin dans le PATH.
exec /usr/bin/gfortran -fno-range-check "$@"
