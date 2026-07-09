# 9cc installer — prefer: gh api contents | base64 decode | iex
# Downloads 9cc.ps1 into ~\.9cc and copies it into a writable PATH dir.
$ErrorActionPreference = 'Stop'
$Home9 = if ($env:CC9_HOME) { $env:CC9_HOME } else { Join-Path $env:USERPROFILE '.9cc' }
$Ver = if ($env:CC9_VERSION) { $env:CC9_VERSION } else {
    $tag = $null
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $tag = gh api repos/investtal/investtal-toolchain/releases/latest --jq '.tag_name' 2>$null
    }
    if (-not $tag) {
        try {
            $resp = Invoke-RestMethod -Uri 'https://api.github.com/repos/investtal/investtal-toolchain/releases/latest' -TimeoutSec 10 -ErrorAction Stop
            if ($resp -and $resp.tag_name) { $tag = $resp.tag_name }
        } catch { }
    }
    if ($tag) { $tag } else { 'v0.3.5' }
}
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
if ($env:CC9_SOURCE -and (Test-Path $env:CC9_SOURCE)) {
    Copy-Item $env:CC9_SOURCE $target -Force      # local fixture (tests)
} elseif ($env:CC9_SOURCE) {
    Invoke-WebRequest $env:CC9_SOURCE -OutFile $target
} else {
    $fetched = $false
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $encoded = gh api "repos/investtal/investtal-toolchain/contents/scripts/9cc.ps1?ref=$Ver" --jq '.content' 2>$null
        if ($encoded) {
            $bytes = [System.Convert]::FromBase64String(($encoded -replace '\s',''))
            [System.IO.File]::WriteAllBytes($target, $bytes)
            $fetched = $true
        }
    }
    if (-not $fetched) {
        $Src = "https://raw.githubusercontent.com/investtal/investtal-toolchain/$Ver/scripts/9cc.ps1"
        Invoke-WebRequest $Src -OutFile $target
    }
}

Copy-Item $target (Join-Path $env:CC9_BIN_DIR '9cc.ps1') -Force
$Ver | Out-File -FilePath (Join-Path $Home9 'version') -NoNewline
Write-Host "9cc installed: $target"
Write-Host "bin copy:      $(Join-Path $env:CC9_BIN_DIR '9cc.ps1')  (add $env:CC9_BIN_DIR to PATH if missing)"
