# 9cc installer — powershell -c "irm <raw url>/install.ps1 | iex"
# Downloads 9cc.ps1 into ~\.9cc and copies it into a writable PATH dir.
$ErrorActionPreference = 'Stop'
$Home9 = if ($env:CC9_HOME) { $env:CC9_HOME } else { Join-Path $env:USERPROFILE '.9cc' }
$Ver   = if ($env:CC9_VERSION) { $env:CC9_VERSION } else { 'v0.3.2' }
$Src   = if ($env:CC9_SOURCE) { $env:CC9_SOURCE } else { "https://raw.githubusercontent.com/investtal/investtal-toolchain/$Ver/scripts/9cc.ps1" }
if (-not $env:CC9_BIN_DIR) {
    $cands = @((Join-Path $env:USERPROFILE '.local\bin'), (Join-Path $env:APPDATA '9cc'), 'C:\Program Files\9cc')
    foreach ($c in $cands) {
        try {
            $null = New-Item -ItemType Directory -Force $c
            $testFile = Join-Path $c '9cc_test_write.tmp'
            [System.IO.File]::WriteAllText($testFile, '')
            Remove-Item $testFile -Force
            $env:CC9_BIN_DIR = $c; break
        } catch {}
    }
}
if (-not $env:CC9_BIN_DIR) { throw "install: no writable bin dir (set CC9_BIN_DIR)" }

New-Item -ItemType Directory -Force $Home9 | Out-Null
$target = Join-Path $Home9 '9cc.ps1'
if (Test-Path $Src) { Copy-Item $Src $target -Force }      # local fixture (tests)
else { Invoke-WebRequest $Src -OutFile $target }

Copy-Item $target (Join-Path $env:CC9_BIN_DIR '9cc.ps1') -Force
$Ver | Out-File -FilePath (Join-Path $Home9 'version') -NoNewline
Write-Host "9cc installed: $target"
Write-Host "bin copy:      $(Join-Path $env:CC9_BIN_DIR '9cc.ps1')  (add $env:CC9_BIN_DIR to PATH if missing)"
