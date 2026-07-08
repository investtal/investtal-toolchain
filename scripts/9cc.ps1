# 9cc — launch Claude Code with a dynamic model over the 9Router gateway.
# Reads auth from ~/.claude/settings.json (read-only). Windows native.
# Usage: 9cc.ps1 list | 9cc.ps1 run <alias-or-id> [claude args...] | 9cc.ps1 help
[CmdletBinding()]
param([switch]$DotSource)
$ErrorActionPreference = 'Stop'
$9ccVersion = if ($env:CC9_VERSION) { $env:CC9_VERSION } else { '0.1.0-dev' }
$SettingsPath = if ($env:CLAUDE_SETTINGS) { $env:CLAUDE_SETTINGS } else { Join-Path ([System.Environment]::GetFolderPath('UserProfile')) '.claude\settings.json' }

$Script:ModelMap = [ordered]@{
    'fable'        = @{ Id='cc/fable-5';                    Window='200000' }
    'opus'         = @{ Id='cc/claude-opus-4-8';            Window='200000' }
    'sonnet'       = @{ Id='cc/claude-sonnet-5';            Window='200000' }
    'haiku'        = @{ Id='cc/claude-haiku-4-5-20251001';  Window='200000' }
    'gpt5'         = @{ Id='cx/gpt-5.5';                    Window='128000' }
    'glm5'         = @{ Id='glm/glm-5.2';                   Window='1000000' }
    'glmturbo'     = @{ Id='glm/glm-5-turbo';               Window='1000000' }
    'deepseek'     = @{ Id='ds/deepseek-v4-pro';            Window='1000000' }
    'dsflash'      = @{ Id='ds/deepseek-v4-flash';          Window='1000000' }
    'kimi'         = @{ Id='kimi/kimi-k2.7';                Window='1000000' }
    'grok'         = @{ Id='gc/grok-build';                 Window='500000' }
    'grokcomposer' = @{ Id='gc/grok-composer-2.5-fast';     Window='500000' }
    'minimax'      = @{ Id='minimax/MiniMax-M3';            Window='1000000' }
}

function Get-Model { param([string]$Key)
    if ($Script:ModelMap.ContainsKey($Key)) { return $Script:ModelMap[$Key] }
    foreach ($v in $Script:ModelMap.Values) { if ($v.Id -eq $Key) { return $v } }
    return $null
}

function Get-Cascade { param([ValidateSet('opus','free')][string]$Tier)
    if ($Tier -eq 'opus') { return @('cc/claude-opus-4-8','cx/gpt-5.5-high','glm/glm-5.2-max') }
    return @('openrouter/poolside/laguna-xs-2.1:free','openrouter/nvidia/nemotron-3-ultra-550b-a55b:free','openrouter/nvidia/nemotron-3.5-content-safety:free','openrouter/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free','openrouter/google/gemma-4-26b-a4b-it:free','openrouter/nvidia/nemotron-3-super-120b-a12b:free','openrouter/qwen/qwen3-next-80b-a3b-instruct:free','openrouter/openai/gpt-oss-120b:free','openrouter/qwen/qwen3-coder:free','openrouter/nousresearch/hermes-3-llama-3.1-405b:free')
}

function Get-NextModel { param([string]$Current,[switch]$NoFree)
    $chain = @(Get-Cascade 'opus')
    if (-not $NoFree) { $chain += @(Get-Cascade 'free') }
    $found = $false
    foreach ($m in $chain) { if ($found) { return $m }; if ($m -eq $Current) { $found = $true } }
    throw "9cc: no successor for '$Current'"
}

function Show-Help {
    Write-Host "9cc - Claude Code model switcher over 9Router"
    Write-Host "Usage:"
    Write-Host "  9cc.ps1 list                    List supported models"
    Write-Host "  9cc.ps1 run <alias|id> [args]   Launch claude with that model (extra args forwarded)"
    Write-Host "  9cc.ps1 version                 Print version"
    Write-Host "  9cc.ps1 help                    Show this help"
    Write-Host "Shortcuts: fable opus sonnet haiku gpt5 glm5 glmturbo deepseek dsflash kimi grok grokcomposer minimax"
    Write-Host "In-session: type /model <id> (e.g. /model glm/glm-5.2) to switch without restarting."
}

function List-Models {
    param([switch]$Json)
    if ($Json) {
        $rows = foreach ($k in $Script:ModelMap.Keys) { $v = $Script:ModelMap[$k]; [pscustomobject]@{alias=$k;id=$v.Id;window=[int]$v.Window} }
        $rows | ConvertTo-Json -Compress
        return
    }
    "{0,-14} {1,-32} {2}" -f 'ALIAS','9ROUTER_ID','WINDOW'
    foreach ($k in $Script:ModelMap.Keys) { $v = $Script:ModelMap[$k]; "{0,-14} {1,-32} {2}" -f $k,$v.Id,$v.Window }
}

function Read-Setting { param([string]$Name)
    if (-not (Test-Path $SettingsPath)) { throw "9cc: settings not found at $SettingsPath" }
    $cfg = try {
        Get-Content -Raw $SettingsPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "9cc: failed to read or parse settings.json at $SettingsPath. Ensure it is valid JSON."
    }
    $val = $cfg.env.$Name
    if (-not $val) { throw "9cc: '$Name' not found in $SettingsPath env block" }
    return $val
}

function Invoke-Session { param([string]$Key,[string[]]$ExtraArgs)
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Error "9cc: 'claude' command not found. Please install Claude Code first."; exit 1
    }
    $m = Get-Model $Key
    if (-not $m) { Write-Error "9cc: unknown model '$Key'. Run '9cc.ps1 list'."; exit 1 }
    $env:CLAUDE_SETTINGS = $SettingsPath
    $env:ANTHROPIC_BASE_URL = Read-Setting 'ANTHROPIC_BASE_URL'
    $env:ANTHROPIC_API_KEY   = Read-Setting 'ANTHROPIC_API_KEY'
    $env:ANTHROPIC_MODEL              = $m.Id
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL   = $m.Id
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $m.Id
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL  = $m.Id
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $m.Window
    Write-Host "9cc -> $($m.Id) (window $($m.Window))" -ForegroundColor Cyan
    if ($ExtraArgs) { & claude @ExtraArgs } else { & claude }
}

if (-not $DotSource) {
    if ($args.Count -eq 0) { Show-Help; return }
    switch ($args[0]) {
        'list' { List-Models -Json:([bool]$args[1]) }
        'next' { if ($args.Count -lt 2) { Write-Error "9cc: missing current model"; exit 1 }
                 try { Get-NextModel $args[1] -NoFree:($args -contains '--no-free') } catch { Write-Error $_.Exception.Message; exit 1 } }
        { $_ -in 'version','-v','--version' } { Write-Host "9cc $9ccVersion" }
        'run'  { if ($args.Count -lt 2) { Write-Error "9cc: missing model. Usage: 9cc.ps1 run <alias|id>"; exit 1 }
                 Invoke-Session -Key $args[1] -ExtraArgs ($args | Select-Object -Skip 2) }
        { $_ -in 'help','-h','--help' } { Show-Help }
        default { Write-Error "9cc: unknown command '$($args[0])'. Run '9cc.ps1 help'."; exit 1 }
    }
}
