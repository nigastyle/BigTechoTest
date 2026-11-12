# Intel oneMKL Linpack: максимальная нагрузка на FPU/AVX + проверка правильности вычислений (residual check).
$TOOLS.Linpack = @{ Url = 'https://downloadmirror.intel.com/931596/w_onemklbench_p_2026.2.0_960.zip'; Sha = 'D4142DE6A544513352763F806F650682DCFC3FCAF0054A05DB0FAC7A64E53586'; Dir = 'Linpack'; Exe = 'Linpack\benchmarks_2026.2\windows\share\mkl\benchmarks\linpack\linpack_xeon64.exe' }
$STEPKEYS['Процессор: Linpack (Intel MKL)'] = 'linpack'
$G.PresetHooks.Add({ param($full) $G.Sel.linpack = $true; $G.Sel.linpackmin = $(if ($full) { 10 } else { 3 }) })
