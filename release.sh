#!/bin/bash
# Выпуск СТАБИЛЬНОЙ версии BigTechoTest на GitHub:  ./release.sh 1.6 "что нового"
# Перед выпуском изменения проверяются тестовой сборкой (./test.sh → папка «Тест» на ПК мастера).
#  1) ставит версию  2) собирает .cmd и .exe (канал stable)  3) подписывает манифест (RSA-3072, ключ только на VDS)
#  4) GitHub Release в публичном nigastyle/BigTechoTest-releases — единственный источник скачивания и автообновления
#  5) коммит + тег в приватном репозитории исходников  6) кладёт выпуск в папку «Стабильная» на ПК мастера
# На VDS программа не публикуется: там только результаты диагностик.
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?версия, например 1.6}"; NOTE="${2:-}"
[[ "$V" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "версия должна быть вида 1.6"; exit 1; }
sed -i "s/^\$VER = '[^']*'/\$VER = '$V'/" pcdiag/body.ps1
bash exe/build-exe.sh | tail -1
grep -q "CHANNEL = 'stable'" pcdiag/PC-Diagnostika.cmd || { echo "сборка не в канале stable"; exit 1; }
R=exe/out/release; mkdir -p "$R"
cp exe/out/BigTechoTest.exe "$R/BigTechoTest.exe"; cp pcdiag/PC-Diagnostika.cmd "$R/BigTechoTest.cmd"; cp pcdiag/ext/BTT-Drivers.ps1 "$R/BTT-Drivers.ps1"
python3 -I - "$V" "$R" <<'PY'
import hashlib, json, os, sys
v, d = sys.argv[1], sys.argv[2]
f = lambda n: {"name": n, "sha256": hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest().upper(), "size": os.path.getsize(os.path.join(d, n))}
j = {"version": v, "files": {"cmd": f("BigTechoTest.cmd"), "exe": f("BigTechoTest.exe"), "drivers": f("BTT-Drivers.ps1")}}
json.dump(j, open(os.path.join(d, "version.json"), "w"), indent=1); print(json.dumps(j))
PY
openssl dgst -sha256 -sign /root/secrets/btt-update-key.pem -out "$R/version.sig.bin" "$R/version.json"
openssl dgst -sha256 -verify btt-update-pub.pem -signature "$R/version.sig.bin" "$R/version.json" >/dev/null
base64 -w0 "$R/version.sig.bin" > "$R/version.sig"
git add -A && git commit -q -m "BigTechoTest $V${NOTE:+: $NOTE}" && git tag "v$V"
gh release create "v$V" --repo nigastyle/BigTechoTest-releases --title "BigTechoTest $V" \
  --notes "${NOTE:-BigTechoTest $V}

**Скачать и запустить: BigTechoTest.exe** (остальные файлы нужны программе для автообновления)." \
  "$R/BigTechoTest.exe" "$R/BigTechoTest.cmd" "$R/BTT-Drivers.ps1" "$R/version.json" "$R/version.sig"
git push -q origin HEAD:main && git push -q origin "v$V"
K="-q -i /root/.ssh/id_ed25519_eqpc -P 2222"; S='C:/Users/EQ/Documents/BigTechoTest/Stable'
if ./winrun '"up"' >/dev/null 2>&1; then
  ./winrun '$s="C:\Users\EQ\Documents\BigTechoTest\Stable"; New-Item -ItemType Directory -Force $s | Out-Null; if (Test-Path "$s\BigTechoTest.exe") { Move-Item "$s\BigTechoTest.exe" ("$s\old-" + (Get-Date -Format HHmmss) + ".old") -Force }' >/dev/null
  scp $K "$R/BigTechoTest.exe" "EQ@localhost:$S/BigTechoTest.exe"; scp $K "$R/BigTechoTest.cmd" "EQ@localhost:$S/BigTechoTest.cmd"
  ./sync-pc.sh >/dev/null
fi
echo "released $V -> https://github.com/nigastyle/BigTechoTest-releases/releases/tag/v$V"
