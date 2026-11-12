#!/bin/bash
# Выпуск новой версии BigTechoTest: ./release.sh 1.4 "что нового"
#  1) ставит версию в body.ps1  2) собирает .cmd и .exe  3) публикует подписанное обновление (автообновление клиентов)
#  4) коммит + тег vX.Y в git и push в GitHub  5) кладёт сборку в v1 на ПК мастера и синхронизирует исходники
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?версия, например 1.4}"; NOTE="${2:-}"
sed -i "s/^\$VER = '[^']*'/\$VER = '$V'/" pcdiag/body.ps1
bash exe/build-exe.sh --publish | tail -1
git add -A && git commit -q -m "BigTechoTest $V${NOTE:+: $NOTE}" && git tag -f "v$V"
if git remote get-url origin >/dev/null 2>&1; then git push -q origin main && git push -q -f origin "v$V"; fi
K="-q -i /root/.ssh/id_ed25519_eqpc -P 2222"
if ./winrun '"up"' >/dev/null 2>&1; then
  ./winrun '$v="C:\Users\EQ\Documents\v1"; if (Test-Path "$v\BigTechoTest.exe") { Move-Item "$v\BigTechoTest.exe" ("$v\BigTechoTest.exe." + (Get-Date -Format HHmmss) + ".old") -Force }' >/dev/null
  scp $K exe/out/BigTechoTest.exe 'EQ@localhost:C:/Users/EQ/Documents/v1/BigTechoTest.exe'
  scp $K pcdiag/PC-Diagnostika.cmd 'EQ@localhost:C:/Users/EQ/Documents/v1/BigTechoTest.cmd'
  ./sync-pc.sh
fi
echo "released $V"
