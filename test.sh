#!/bin/bash
# Тестовая (предрелизная) сборка BigTechoTest → папка «Тест» на ПК мастера. На GitHub НЕ попадает, сама не обновляется.
# Все изменения сначала проверяются здесь; когда всё стабильно — ./release.sh X.Y "что нового"
set -euo pipefail
cd "$(dirname "$0")"
BTT_CHANNEL=test bash exe/build-exe.sh | tail -1
K="-q -i /root/.ssh/id_ed25519_eqpc -P 2222"; T='C:/Users/EQ/Documents/BigTechoTest/Test'
./winrun '$t="C:\Users\EQ\Documents\BigTechoTest\Test"; New-Item -ItemType Directory -Force $t | Out-Null; if (Test-Path "$t\BigTechoTest-TEST.exe") { Move-Item "$t\BigTechoTest-TEST.exe" ("$t\old-" + (Get-Date -Format HHmmss) + ".old") -Force }; gci $t *.old | % { try { Remove-Item $_.FullName -Force -EA Stop } catch {} }' >/dev/null
scp $K exe/out/BigTechoTest.exe "EQ@localhost:$T/BigTechoTest-TEST.exe"
scp $K pcdiag/PC-Diagnostika.cmd "EQ@localhost:$T/BigTechoTest-TEST.cmd"
[ -f pcdiag/ext/BTT-Drivers.ps1 ] && scp $K pcdiag/ext/BTT-Drivers.ps1 "EQ@localhost:$T/BTT-Drivers.ps1" || true
bash pcdiag/build.sh >/dev/null   # вернуть рабочую копию .cmd к стабильному каналу
echo "test build $(grep -m1 "^.VER = " pcdiag/body.ps1 | sed -E "s/.*'([^']+)'.*/\1/") -> $T"
