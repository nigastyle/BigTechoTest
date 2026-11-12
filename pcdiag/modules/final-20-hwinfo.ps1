# Итог по HWiNFO: все датчики за время тестов (мин/макс/среднее) и закрытие HWiNFO, если его запускали мы
if (Get-Command Hwi-Report -ErrorAction SilentlyContinue) {
    Step 'HWiNFO: все датчики за время тестов' {
        if (-not $G.HwiStarted) { Info 'HWiNFO не запускался (стресс-тестов не было)'; return }
        $s = New-Section 'HWiNFO: все датчики за время тестов'
        try { Hwi-Report $s } catch { $G.Log.Add('Hwi-Report: ' + $_.Exception.Message) }
        try { Stop-HWiNFO } catch {}
    }
}
