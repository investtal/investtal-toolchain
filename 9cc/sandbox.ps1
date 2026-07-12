# 9cc sandbox helpers — PowerShell mirror of sandbox.sh
$ErrorActionPreference = 'Stop'

$CC9Home = if ($env:CC9_HOME) { $env:CC9_HOME } else { Join-Path $env:USERPROFILE '.9cc' }
$SettingsPath = if ($env:CLAUDE_SETTINGS) { $env:CLAUDE_SETTINGS } else { Join-Path $env:USERPROFILE '.claude\settings.json' }
$SandboxImage = if ($env:CC9_SANDBOX_IMAGE) { $env:CC9_SANDBOX_IMAGE } else { '9cc-sandbox:latest' }
$SandboxContext = if ($env:CC9_SANDBOX_CONTEXT) { $env:CC9_SANDBOX_CONTEXT } else { Join-Path $CC9Home 'sandbox-context' }

$CC9SandboxDir = if ($env:CC9_SANDBOX_DIR) { $env:CC9_SANDBOX_DIR } else { $PSScriptRoot }

function Test-GuardedDir {
    param([string]$Path)
    $resolved = (Resolve-Path $Path).Path.TrimEnd('\','/')
    $homeResolved = (Resolve-Path $env:USERPROFILE).Path.TrimEnd('\','/')
    $root = ([System.IO.Path]::GetPathRoot($resolved)).TrimEnd('\','/')
    if ($resolved -eq $homeResolved -or $resolved -eq $root -or $resolved -eq '/') {
        return $true
    }
    return $false
}

function Copy-IfExists {
    param([string]$Source, [string]$Destination)
    if (Test-Path $Source) { Copy-Item -Recurse -Force $Source $Destination }
}

function Test-IsLinuxElf {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 4
        if ($fs.Read($buf, 0, 4) -lt 4) { return $false }
        return ($buf[0] -eq 0x7F -and $buf[1] -eq 0x45 -and $buf[2] -eq 0x4C -and $buf[3] -eq 0x46)
    } finally { $fs.Dispose() }
}

function Test-IsContainerRunnableClaude {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if (Test-IsLinuxElf $Path) { return $true }
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 2
        if ($fs.Read($buf, 0, 2) -lt 2) { return $false }
        return ($buf[0] -eq 0x23 -and $buf[1] -eq 0x21)  # #!
    } finally { $fs.Dispose() }
}

function Resolve-FullPath {
    param([string]$Path)
    try { return (Resolve-Path -LiteralPath $Path).Path } catch { return $Path }
}

# Returns hashtable: @{ Kind = 'dir'|'bin'|'npm'; Path = string }
function Find-ClaudeSource {
    if ($env:CC9_CLAUDE_LOCAL) {
        if (-not (Test-Path -LiteralPath $env:CC9_CLAUDE_LOCAL -PathType Container)) {
            throw "9cc sandbox: CC9_CLAUDE_LOCAL=$($env:CC9_CLAUDE_LOCAL) is not a directory"
        }
        return @{ Kind = 'dir'; Path = $env:CC9_CLAUDE_LOCAL }
    }

    if ($env:CC9_CLAUDE_BIN) {
        if (-not (Test-Path -LiteralPath $env:CC9_CLAUDE_BIN -PathType Leaf)) {
            throw "9cc sandbox: CC9_CLAUDE_BIN=$($env:CC9_CLAUDE_BIN) not found"
        }
        $resolved = Resolve-FullPath $env:CC9_CLAUDE_BIN
        if (Test-IsContainerRunnableClaude $resolved) {
            return @{ Kind = 'bin'; Path = $resolved }
        }
        Write-Host "9cc sandbox: CC9_CLAUDE_BIN=$resolved is not Linux-runnable; falling back to npm install in image" -ForegroundColor Yellow
        return @{ Kind = 'npm'; Path = '' }
    }

    $legacy = Join-Path $env:USERPROFILE '.claude\local'
    if (Test-Path -LiteralPath $legacy -PathType Container) {
        $candidate = $null
        $binClaude = Join-Path $legacy 'bin\claude'
        $flatClaude = Join-Path $legacy 'claude'
        if (Test-Path -LiteralPath $binClaude -PathType Leaf) { $candidate = $binClaude }
        elseif (Test-Path -LiteralPath $flatClaude -PathType Leaf) { $candidate = $flatClaude }
        if ($candidate -and (Test-IsContainerRunnableClaude (Resolve-FullPath $candidate))) {
            return @{ Kind = 'dir'; Path = $legacy }
        }
        if ($candidate) {
            Write-Host "9cc sandbox: $legacy has a non-Linux claude binary; trying PATH / npm" -ForegroundColor Yellow
        }
    }

    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        $resolved = Resolve-FullPath $cmd.Source
        if (Test-IsContainerRunnableClaude $resolved) {
            return @{ Kind = 'bin'; Path = $resolved }
        }
        Write-Host "9cc sandbox: host claude at $resolved is not Linux-runnable; installing Claude Code via npm in the image" -ForegroundColor Yellow
        return @{ Kind = 'npm'; Path = '' }
    }

    $candidates = @()
    $localBin = Join-Path $env:USERPROFILE '.local\bin\claude'
    if (Test-Path -LiteralPath $localBin) { $candidates += $localBin }
    $versions = Join-Path $env:USERPROFILE '.local\share\claude\versions'
    if (Test-Path -LiteralPath $versions) {
        $candidates += Get-ChildItem -LiteralPath $versions -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    }
    foreach ($c in $candidates) {
        $resolved = Resolve-FullPath $c
        if (Test-IsContainerRunnableClaude $resolved) {
            return @{ Kind = 'bin'; Path = $resolved }
        }
    }

    Write-Host "9cc sandbox: no host Claude install found; installing Claude Code via npm in the image" -ForegroundColor Yellow
    return @{ Kind = 'npm'; Path = '' }
}

function Stage-ClaudeLocal {
    param([string]$ContextDir)
    $src = Find-ClaudeSource
    $dest = Join-Path $ContextDir 'claude-local'
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }

    switch ($src.Kind) {
        'dir' {
            Copy-Item -Recurse -Force $src.Path $dest
            $destBin = Join-Path $dest 'bin\claude'
            $destFlat = Join-Path $dest 'claude'
            if (-not (Test-Path $destBin) -and (Test-Path $destFlat)) {
                New-Item -ItemType Directory -Force (Join-Path $dest 'bin') | Out-Null
                Copy-Item -Force $destFlat $destBin
            }
            Set-Content -Path (Join-Path $ContextDir 'claude-source.mode') -Value 'host' -NoNewline
            Write-Host "9cc sandbox: using host Claude dir $($src.Path)" -ForegroundColor Cyan
        }
        'bin' {
            $binDir = Join-Path $dest 'bin'
            New-Item -ItemType Directory -Force $binDir | Out-Null
            Copy-Item -Force $src.Path (Join-Path $binDir 'claude')
            Set-Content -Path (Join-Path $ContextDir 'claude-source.mode') -Value 'host' -NoNewline
            Write-Host "9cc sandbox: using host Claude binary $($src.Path)" -ForegroundColor Cyan
        }
        'npm' {
            New-Item -ItemType Directory -Force $dest | Out-Null
            Set-Content -Path (Join-Path $dest '.npm-install') -Value '# npm install inside image'
            Set-Content -Path (Join-Path $ContextDir 'claude-source.mode') -Value 'npm' -NoNewline
        }
        default { throw "9cc sandbox: internal error: unknown claude source kind '$($src.Kind)'" }
    }
}

function Build-SandboxImage {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw '9cc sandbox: docker not found' }

    # Guard: only wipe our own managed context dir to avoid data loss if user overrides CC9_SANDBOX_CONTEXT.
    $homeNorm = (Resolve-Path $CC9Home).Path
    $isManaged = ($SandboxContext -like "$homeNorm*") -or ($SandboxContext -like "$([System.IO.Path]::GetTempPath())*")
    if (-not $isManaged) { throw "9cc sandbox: refusing to wipe CC9_SANDBOX_CONTEXT=$SandboxContext (must be under `$CC9_HOME or temp)" }
    if (Test-Path $SandboxContext) { Remove-Item -Recurse -Force $SandboxContext }
    New-Item -ItemType Directory -Force $SandboxContext | Out-Null

    Stage-ClaudeLocal -ContextDir $SandboxContext
    Copy-IfExists (Join-Path $env:USERPROFILE '.claude') (Join-Path $SandboxContext 'claude')
    # Never bake secrets or the host binary into image layers; both are supplied at runtime.
    Remove-Item -Recurse -Force (Join-Path $SandboxContext 'claude\settings.json') -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $SandboxContext 'claude\local') -ErrorAction SilentlyContinue
    Copy-IfExists (Join-Path $env:USERPROFILE '.investtal') (Join-Path $SandboxContext 'investtal')
    Copy-IfExists (Join-Path $env:USERPROFILE '.proto') (Join-Path $SandboxContext 'proto')
    Copy-IfExists (Join-Path $env:USERPROFILE '.prototools') (Join-Path $SandboxContext 'prototools')
    Copy-IfExists (Join-Path $env:USERPROFILE '.zshrc') (Join-Path $SandboxContext 'zshrc')
    Copy-IfExists (Join-Path $env:USERPROFILE '.zshenv') (Join-Path $SandboxContext 'zshenv')

    $zshrc = Join-Path $SandboxContext 'zshrc'
    $zshenv = Join-Path $SandboxContext 'zshenv'
    if (-not (Test-Path $zshrc)) { New-Item -ItemType File -Path $zshrc | Out-Null }
    if (-not (Test-Path $zshenv)) { New-Item -ItemType File -Path $zshenv | Out-Null }

    $thisDir = $CC9SandboxDir
    Copy-Item (Join-Path $thisDir 'agent-proxy.mjs') (Join-Path $SandboxContext 'agent-proxy.mjs') -Force
    Copy-Item (Join-Path $thisDir 'sandbox-entrypoint.sh') (Join-Path $SandboxContext 'sandbox-entrypoint.sh') -Force

    $df = Join-Path $thisDir 'Dockerfile'
    if (-not (Test-Path $df)) { throw "9cc sandbox: Dockerfile not found at $df" }

    & docker build -t $SandboxImage -f $df $SandboxContext
}

function Get-EgressDir {
    $dir = Join-Path $CC9Home 'egress'
    New-Item -ItemType Directory -Force $dir | Out-Null
    return $dir
}

function Invoke-SandboxRun {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw '9cc sandbox: docker not found' }
    $cwd = (Resolve-Path '.').Path
    if (Test-GuardedDir $cwd) { throw "9cc sandbox: refusing to run in $cwd (mount would expose home or root)" }

    if ($env:CC9_SANDBOX_NO_BUILD -ne '1') {
        try { docker image inspect $SandboxImage | Out-Null } catch { Build-SandboxImage }
    }

    if (-not (Test-Path $SettingsPath)) { throw "9cc sandbox: $SettingsPath not found" }

    $egress = Get-EgressDir
    Write-Host "9cc sandbox: egress logs -> $egress" -ForegroundColor Cyan

    $dockerArgs = @('run', '--rm', '-it')
    # Native Windows has no meaningful Linux uid/gid mapping; use container defaults.
    # On PowerShell Core on Linux/macOS/WSL, map the host uid/gid so bind mounts align.
    if (Get-Command id -ErrorAction SilentlyContinue) {
        $uid = (& id -u).Trim()
        $gid = (& id -g).Trim()
        $dockerArgs += @('--user', "$uid`:$gid")
        $userName = (& id -un).Trim()
    } else {
        $userName = $env:USERNAME
    }
    $dockerArgs += @(
        '--workdir', '/workspace',
        '-v', "$($cwd):/workspace",
        '-v', "$($SettingsPath):/home/9cc/.claude/settings.json:ro",
        '-v', "$($egress):/tmp/9cc-egress",
        '-e', 'HOME=/home/9cc',
        '-e', "USER=$userName",
        '-e', "TERM=$env:TERM",
        '-e', "ANTHROPIC_MODEL=$env:ANTHROPIC_MODEL",
        '-e', "ANTHROPIC_DEFAULT_OPUS_MODEL=$env:ANTHROPIC_DEFAULT_OPUS_MODEL",
        '-e', "ANTHROPIC_DEFAULT_SONNET_MODEL=$env:ANTHROPIC_DEFAULT_SONNET_MODEL",
        '-e', "ANTHROPIC_DEFAULT_HAIKU_MODEL=$env:ANTHROPIC_DEFAULT_HAIKU_MODEL",
        '-e', "CLAUDE_CODE_AUTO_COMPACT_WINDOW=$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW",
        '-e', "ANTHROPIC_BASE_URL=$env:ANTHROPIC_BASE_URL",
        '-e', "ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY",
        $SandboxImage,
        'claude'
    ) + $args

    & docker @dockerArgs
}
