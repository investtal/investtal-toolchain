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

function Build-SandboxImage {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw '9cc sandbox: docker not found' }
    $claudeLocal = Join-Path $env:USERPROFILE '.claude\local'
    if (-not (Test-Path $claudeLocal)) { throw "9cc sandbox: $claudeLocal not found; install Claude Code first" }

    # Guard: only wipe our own managed context dir to avoid data loss if user overrides CC9_SANDBOX_CONTEXT.
    $homeNorm = (Resolve-Path $CC9Home).Path
    $isManaged = ($SandboxContext -like "$homeNorm*") -or ($SandboxContext -like "$([System.IO.Path]::GetTempPath())*")
    if (-not $isManaged) { throw "9cc sandbox: refusing to wipe CC9_SANDBOX_CONTEXT=$SandboxContext (must be under `$CC9_HOME or temp)" }
    if (Test-Path $SandboxContext) { Remove-Item -Recurse -Force $SandboxContext }
    New-Item -ItemType Directory -Force $SandboxContext | Out-Null

    Copy-IfExists $claudeLocal (Join-Path $SandboxContext 'claude-local')
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
