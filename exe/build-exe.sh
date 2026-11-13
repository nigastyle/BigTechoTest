#!/bin/bash
# Пересобрать PC-Diagnostika.cmd, упаковать в PC-Diagnostika.exe.
# (публикация выпуска — release.sh; на VDS программа не выкладывается)
set -e; D=$(cd "$(dirname "$0")" && pwd)
bash "$D/../pcdiag/build.sh"
cd "$D" && DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet build -c Release -o out | tail -2
rm -f out/BigTechoTest.exe.config; ls -la out/BigTechoTest.exe
if [ "${1:-}" = "--publish" ]; then
  V=$(grep -m1 "^.VER = " "$D/../pcdiag/body.ps1" | sed -E "s/.*'([^']+)'.*/\1/")
  pcdiag-publish "$V" "$D/../pcdiag/PC-Diagnostika.cmd" "$D/out/BigTechoTest.exe" "$D/../pcdiag/ext/BTT-Drivers.ps1"
fi
