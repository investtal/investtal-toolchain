$ErrorActionPreference = 'Stop'

function Select-Latest9ccTag {
    param([string[]]$Tags)
    $nine = @(
        $Tags |
            Where-Object { $_ -match '^9cc-v\d+\.\d+\.\d+$' } |
            ForEach-Object { $_.Substring(5) } |
            Sort-Object { [version]$_ }
    )
    if ($nine.Count -gt 0) { return "9cc-v$($nine[-1])" }
    $legacy = @(
        $Tags |
            Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } |
            ForEach-Object { $_.Substring(1) } |
            Sort-Object { [version]$_ }
    )
    if ($legacy.Count -gt 0) { return "v$($legacy[-1])" }
    return $null
}

function Resolve-Latest9ccTag {
    $tags = @()
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        try {
            $raw = gh api 'repos/investtal/investtal-toolchain/releases?per_page=100' --jq '.[].tag_name' 2>$null
            if ($raw) {
                $tags = @($raw -split "[\r\n]+" | Where-Object { $_ })
            }
        } catch { }
    }
    if ($tags.Count -eq 0) {
        try {
            $resp = Invoke-RestMethod -Uri 'https://api.github.com/repos/investtal/investtal-toolchain/releases?per_page=100' -TimeoutSec 15 -ErrorAction Stop
            if ($resp) {
                $tags = @($resp | ForEach-Object { $_.tag_name } | Where-Object { $_ })
            }
        } catch { }
    }
    return (Select-Latest9ccTag -Tags $tags)
}

$Home9 = if ($env:CC9_HOME) { $env:CC9_HOME } else { Join-Path $env:USERPROFILE '.9cc' }
$Ver = if ($env:CC9_VERSION) { $env:CC9_VERSION } else {
    $tag = Resolve-Latest9ccTag
    if ($tag) { $tag } else { 'v0.5.4' }
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
function Install-AtomicFile([string]$Dest, [scriptblock]$Writer) {
    $dir = Split-Path -Parent $Dest
    $tmp = Join-Path $dir ('.9cc-install.' + [guid]::NewGuid().ToString('N'))
    & $Writer $tmp
    Move-Item -LiteralPath $tmp -Destination $Dest -Force
}
if ($env:CC9_SOURCE -and (Test-Path $env:CC9_SOURCE)) {
    Install-AtomicFile $target { param($t) Copy-Item $env:CC9_SOURCE $t -Force }
} elseif ($env:CC9_SOURCE) {
    Install-AtomicFile $target { param($t) Invoke-WebRequest $env:CC9_SOURCE -OutFile $t }
} else {
    $fetched = $false
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $encoded = gh api "repos/investtal/investtal-toolchain/contents/9cc/9cc.ps1?ref=$Ver" --jq '.content' 2>$null
        if ($encoded) {
            $bytes = [System.Convert]::FromBase64String(($encoded -replace '\s',''))
            Install-AtomicFile $target { param($t) [System.IO.File]::WriteAllBytes($t, $bytes) }
            $fetched = $true
        }
    }
    if (-not $fetched) {
        $Src = "https://raw.githubusercontent.com/investtal/investtal-toolchain/$Ver/9cc/9cc.ps1"
        Install-AtomicFile $target { param($t) Invoke-WebRequest $Src -OutFile $t }
    }
}

Copy-Item $target (Join-Path $env:CC9_BIN_DIR '9cc.ps1') -Force

$localSrc = $env:CC9_SOURCE -and (Test-Path $env:CC9_SOURCE)
$srcDir = if ($localSrc) { Split-Path $env:CC9_SOURCE } else { $PSScriptRoot }
function Install-Asset($Name) {
    $dst = Join-Path $Home9 $Name
    if ($localSrc) {
        $src = Join-Path $srcDir $Name
        if (Test-Path $src) { Copy-Item $src $dst -Force }
    } else {
        $src = "https://raw.githubusercontent.com/investtal/investtal-toolchain/$Ver/9cc/$Name"
        try { Invoke-WebRequest $src -OutFile $dst -TimeoutSec 30 -ErrorAction Stop } catch {
            Write-Host "install: warning: could not fetch $Name from $src"
        }
    }
}
foreach ($f in @('Dockerfile', 'agent-proxy.mjs', 'sandbox-entrypoint.sh', 'sandbox.ps1')) {
    Install-Asset $f
}

$Ver | Out-File -FilePath (Join-Path $Home9 'version') -NoNewline
Write-Host "9cc installed: $target"
Write-Host "bin copy:      $(Join-Path $env:CC9_BIN_DIR '9cc.ps1')  (add $env:CC9_BIN_DIR to PATH if missing)"
