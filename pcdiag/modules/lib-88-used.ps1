# Ключи выбора: «Проверка Б/У перед покупкой» (used) и «Тест поддельного объёма флешки» (fakeflash).
# Оба выключены по умолчанию. Включаются галочкой в UI или режимом по жалобе / покупки Б/У:
#   в каталоге жалоб (lib-70-complaint) добавить в Tests:  used = $true
# Для автотестов: переменная окружения DIAG_USED=1 включает проверку Б/У, DIAG_FAKEFLASH=1 - тест флешек.
$STEPKEYS['Проверка Б/У: износ и следы'] = 'used'
$STEPKEYS['Поиск подделок: тест объёма флешки'] = 'fakeflash'
$G.PresetHooks.Add({ param($full)
        $G.Sel.used = ($env:DIAG_USED -eq '1')
        $G.Sel.fakeflash = ($env:DIAG_FAKEFLASH -eq '1')
    })
