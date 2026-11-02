# Run pin-level I2C protocol/fault tests plus FFT and speed capture.
# Usage:  pwsh -File sim/run_sim.ps1
$ErrorActionPreference = 'Stop'
$VIV = if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { Split-Path (Get-Command xvlog.bat -ErrorAction Stop).Source }
$ROOT = Split-Path -Parent $PSScriptRoot
$WORK = Join-Path $ROOT 'sim\work'
$PYTHON = if ($env:VIB_PYTHON) { $env:VIB_PYTHON } else { (Get-Command python -ErrorAction Stop).Source }
New-Item -ItemType Directory -Path $WORK -Force | Out-Null
& $PYTHON (Join-Path $ROOT 'sim\check_numeric.py') generate
if ($LASTEXITCODE -ne 0) { throw 'Numeric fixture generation failed' }

# --- generate single-tone frame: 3000*sin(2*pi*8*n/1024), 16-bit two's complement hex ---
$sb = New-Object System.Text.StringBuilder
for ($n=0; $n -lt 1024; $n++) {
    $v = [int][math]::Round(3000.0 * [math]::Sin(2.0*[math]::PI*8.0*$n/1024.0))
    if ($v -lt 0) { $v = $v + 65536 }
    [void]$sb.AppendLine(('{0:X4}' -f ($v -band 0xFFFF)))
}
[System.IO.File]::WriteAllText((Join-Path $WORK 'sine_frame.mem'), $sb.ToString())

# --- copy ROM init files into the sim work dir (for $readmemh) ---
Copy-Item (Join-Path $ROOT 'build\twiddle.mem') $WORK -Force
Copy-Item (Join-Path $ROOT 'build\hann.mem')    $WORK -Force

$srcs = (Get-ChildItem (Join-Path $ROOT 'src') -Filter *.v | ForEach-Object { $_.FullName })
$testNames = @('tb_adxl345_i2c','tb_fft','tb_speed','tb_vib_axi')
$tbs = @($testNames | ForEach-Object { Join-Path $ROOT "sim\$_.v" })

Push-Location $WORK
try {
    $glbl = Join-Path $VIV '..\data\verilog\src\glbl.v'
    & "$VIV\xvlog.bat" @srcs @tbs $glbl 2>&1 | Out-File -Encoding utf8 console_xvlog.txt
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed (see sim/work/xvlog.log)" }

    foreach ($tb in $testNames) {
        & "$VIV\xelab.bat" -L unisims_ver -debug off $tb glbl -s "${tb}_sim" 2>&1 | Out-File -Encoding utf8 "console_xelab_$tb.txt"
        if ($LASTEXITCODE -ne 0) { throw "xelab $tb failed" }
        & "$VIV\xsim.bat" "${tb}_sim" -runall 2>&1 | Out-File -Encoding utf8 "console_xsim_$tb.txt"
        if ($LASTEXITCODE -ne 0) { throw "xsim $tb failed" }
        # xsim can exit 0 even after Verilog $fatal. Require the explicit PASS
        # marker AND reject failure/fatal text; process exit alone is not proof.
        $logText = Get-Content -LiteralPath "console_xsim_$tb.txt" -Raw
        $marker = switch ($tb) { 'tb_adxl345_i2c' { 'TB_I2C' }; 'tb_fft' { 'TB_FFT' }; 'tb_speed' { 'TB_SPEED' }; default { 'TB_AXI' } }
        if ($logText -match '(?im)\bFAIL\b|^Fatal:|^ERROR:' -or
            $logText -notmatch ($marker + ': PASS')) {
            throw "Simulation assertions failed or no PASS marker for $tb (see sim/work/console_xsim_$tb.txt)"
        }
    }
} finally {
    Pop-Location
}
Write-Output "SIM DONE -> $WORK"
& $PYTHON (Join-Path $ROOT 'sim\check_numeric.py') check
if ($LASTEXITCODE -ne 0) { throw 'FFT reference comparison failed' }
foreach ($tb in $testNames) {
    Get-Content (Join-Path $WORK "console_xsim_$tb.txt") | Select-String -Pattern 'TB_I2C|TB_FFT|TB_SPEED|TB_AXI'
}
& $PYTHON (Join-Path $ROOT 'sim\test_host.py')
if ($LASTEXITCODE -ne 0) { throw 'Python host regression failed' }
