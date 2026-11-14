#!/bin/bash
# Сборка PC-Diagnostika.cmd: заголовок cmd + body.ps1 с вставленными core.cs/ui.cs, CRLF, UTF-8 без BOM
D=$(dirname "$0")
python3 - "$D" <<'PY'
import sys,os
d=sys.argv[1]
body=open(os.path.join(d,'body.ps1'),encoding='utf-8').read()
body=body.replace('%%CORE_CS%%',open(os.path.join(d,'core.cs'),encoding='utf-8').read().rstrip('\n'))
body=body.replace('%%UI_CS%%',open(os.path.join(d,'ui.cs'),encoding='utf-8').read().rstrip('\n'))
# значок приложения (exe/app.ico) встраивается в сам скрипт
import base64
assert body.count('%%APP_ICO_B64%%')==1
body=body.replace('%%APP_ICO_B64%%', base64.b64encode(open(os.path.join(d,'..','exe','app.ico'),'rb').read()).decode())
# канал сборки: BTT_CHANNEL=test — предрелизная (не обновляется сама)
ch=os.environ.get('BTT_CHANNEL','stable')
assert body.count("$CHANNEL = 'stable'")==1
if ch!='stable': body=body.replace("$CHANNEL = 'stable'","$CHANNEL = '%s'"%ch)
# модули: строка '#%%MOD:имя%%' заменяется содержимым modules/имя-*.ps1 (по алфавиту)
import glob,re
def mod(m):
    fs=sorted(glob.glob(os.path.join(d,'modules',m.group(1)+'-*.ps1')))
    return '\n'.join('# ---- модуль '+os.path.basename(f)+'\n'+open(f,encoding='utf-8-sig').read().rstrip('\n') for f in fs) or '# (модулей '+m.group(1)+' нет)'
body=re.sub(r'(?m)^#%%MOD:(\w+)%%$', mod, body)
# защита от затирания глобальных переменных ($g == $G, $ic == $IC в PowerShell)
bad=[(m.group(0)) for m in re.finditer(r'(?m)^.*(\$(g|ic|stepkeys|tools|upload)\s*=[^=]|\((\$(g|ic))\s+in\b).*$', re.sub(r'(?s)@\'.*?\'@','',body))]
if bad:
    sys.exit('BUILD ERROR: variable shadows a global:\n  ' + '\n  '.join(b.strip()[:120] for b in bad))
for f in glob.glob(os.path.join(d,'modules','*.ps1')):
    if not os.path.basename(f).startswith('lib-') and 'PresetHooks.Add' in open(f,encoding='utf-8-sig').read():
        sys.exit('BUILD ERROR: PresetHooks.Add must be in a lib- module (presets are applied before other anchors): '+f)
# список всех шагов (для онлайн-окна) — в порядке выполнения
steps=[]
for n in re.findall(r"(?m)^Step '(.+?)'\s*\{", body):
    if n not in steps: steps.append(n)
body=body.replace('#%%STEPLIST%%', '$G.AllSteps = @(' + ','.join("'"+n.replace("'","''")+"'" for n in steps) + ')')
# ВНИМАНИЕ: заголовок НЕ МЕНЯТЬ — от его байтовой длины зависит безопасное автообновление запущенного .cmd
head='''<# : batch
@echo off
chcp 65001 >nul
title PC Diagnostika
net session >nul 2>&1
if not errorlevel 1 goto :run
echo Requesting administrator rights...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b
:run
set "DIAG_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:DIAG_SELF,[Text.Encoding]::UTF8))"
exit /b
#>
'''
assert "'@" not in open(os.path.join(d,'core.cs')).read() and "'@" not in open(os.path.join(d,'ui.cs')).read()
out=(head+body).replace('\r\n','\n').replace('\n','\r\n')
open(os.path.join(d,'PC-Diagnostika.cmd'),'w',encoding='utf-8',newline='').write(out)
print('built', len(out))
PY
