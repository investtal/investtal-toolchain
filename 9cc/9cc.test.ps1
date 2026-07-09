# 9cc.ps1 TDD harness. Assert-based. Run: pwsh -File 9cc/9cc.test.ps1
$ErrorActionPreference = 'Stop'
$DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Pass = 0; $script:Fail = 0
function Assert-Eq($a, $b, $label) {
    if ($a -eq $b) { Write-Host "  ok: $label"; $script:Pass++ }
    else { Write-Host "  FAIL: $label - want '$b' got '$a'"; $script:Fail++ }
}
. "$DIR/9cc.ps1" -DotSource

Write-Host "Cycle 1: registry 13 aliases"
$want = @{
  fable=@{Id='cc/claude-fable-5';Window='1000000'}; opus=@{Id='cc/claude-opus-4-8';Window='1000000'}
  sonnet=@{Id='cc/claude-sonnet-5';Window='200000'}; haiku=@{Id='cc/claude-haiku-4-5-20251001';Window='200000'}
  gpt5=@{Id='cx/gpt-5.5';Window='128000'}; glm5=@{Id='glm/glm-5.2';Window='1000000'}
  glmturbo=@{Id='glm/glm-5-turbo';Window='1000000'}; deepseek=@{Id='ds/deepseek-v4-pro';Window='1000000'}
  dsflash=@{Id='ds/deepseek-v4-flash';Window='1000000'}; kimi=@{Id='kimi/kimi-k2.7';Window='1000000'}
  grok=@{Id='xai/grok-4.5';Window='500000'}; grokcomposer=@{Id='xai/grok-composer-2.5-fast';Window='500000'}
  minimax=@{Id='minimax/MiniMax-M3';Window='1000000'}
}
foreach ($k in $want.Keys) {
    $m = Get-Model $k
    Assert-Eq $m.Id $want[$k].Id "$k id"
    Assert-Eq $m.Window $want[$k].Window "$k window"
}

Write-Host "Cycle 2: full-ID resolve"
$f = Get-Model 'glm/glm-5.2'; Assert-Eq $f.Id 'glm/glm-5.2' "full glm"
$f2 = Get-Model 'cc/claude-fable-5'; Assert-Eq $f2.Id 'cc/claude-fable-5' "full fable"

Write-Host "Cycle 3: unknown -> null"
if ($null -eq (Get-Model 'nope')) { Write-Host "  ok: unknown null"; $script:Pass++ } else { Write-Host "  FAIL"; $script:Fail++ }

Write-Host "Cycle 4: list prints all"
$out = List-Models
foreach ($k in $want.Keys) { if ($out -match $k) { Write-Host "  ok: list has $k"; $script:Pass++ } else { Write-Host "  FAIL: list missing $k"; $script:Fail++ } }

Write-Host "Cycle 5: install.ps1 downloads (fixture source)"
$env:CC9_VERSION = 'v0.3.5'
$env:CC9_SOURCE = "$DIR\9cc.ps1"
$env:CC9_HOME   = Join-Path $env:TEMP "9cc-home"
$env:CC9_BIN_DIR = Join-Path $env:TEMP "9cc-bin"
Remove-Item -Recurse -Force $env:CC9_HOME,$env:CC9_BIN_DIR -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $env:CC9_BIN_DIR | Out-Null
& "$DIR\install.ps1"
if (Test-Path (Join-Path $env:CC9_HOME '9cc.ps1')) { Write-Host "  ok: downloaded"; $script:Pass++ } else { Write-Host "  FAIL: not downloaded"; $script:Fail++ }
if (Test-Path (Join-Path $env:CC9_BIN_DIR '9cc.ps1')) { Write-Host "  ok: bin copy"; $script:Pass++ } else { Write-Host "  FAIL: no bin copy"; $script:Fail++ }
& "$DIR\install.ps1"
Write-Host "  ok: re-run ok"; $script:Pass++
Remove-Item -Recurse -Force $env:CC9_HOME,$env:CC9_BIN_DIR -ErrorAction SilentlyContinue
Remove-Item Env:CC9_SOURCE,Env:CC9_HOME,Env:CC9_BIN_DIR -ErrorAction SilentlyContinue

Write-Host "Cycle 5b: family-aware DEFAULT_{OPUS,SONNET,HAIKU} tiers"
$stubDir = Join-Path $env:TEMP '9cc-test-bin'
New-Item -ItemType Directory -Force $stubDir | Out-Null
$stub = @'
#!/usr/bin/env pwsh
Write-Output "MODEL=$env:ANTHROPIC_MODEL"
Write-Output "OPUS=$env:ANTHROPIC_DEFAULT_OPUS_MODEL"
Write-Output "SONNET=$env:ANTHROPIC_DEFAULT_SONNET_MODEL"
Write-Output "HAIKU=$env:ANTHROPIC_DEFAULT_HAIKU_MODEL"
'@
# Windows stub as .cmd that echoes env via powershell is heavy; use function override by PATH
# Prefer a .ps1 shim named claude.cmd calling powershell -Command Write-Output
$cmd = @"
@echo off
echo MODEL=%ANTHROPIC_MODEL%
echo OPUS=%ANTHROPIC_DEFAULT_OPUS_MODEL%
echo SONNET=%ANTHROPIC_DEFAULT_SONNET_MODEL%
echo HAIKU=%ANTHROPIC_DEFAULT_HAIKU_MODEL%
"@
Set-Content -Path (Join-Path $stubDir 'claude.cmd') -Value $cmd -Encoding ASCII
$settings = Join-Path $env:TEMP '9cc-test-settings.json'
'{"env":{"ANTHROPIC_BASE_URL":"https://gw.example/v1","ANTHROPIC_API_KEY":"sk-test"}}' | Set-Content -Path $settings -Encoding UTF8
$env:CLAUDE_SETTINGS = $settings
$oldPath = $env:PATH
$env:PATH = "$stubDir;$env:PATH"

function Assert-Out($label, $out, $pat) {
  if ($out -match [regex]::Escape($pat)) { Write-Host "  ok: $label"; $script:Pass++ }
  else { Write-Host "  FAIL: $label want '$pat' got:`n$out"; $script:Fail++ }
}

$fable = & "$DIR\9cc.ps1" run fable 2>$null | Out-String
Assert-Out 'fable MODEL' $fable 'MODEL=cc/claude-fable-5'
Assert-Out 'fable OPUS=fable' $fable 'OPUS=cc/claude-fable-5'
Assert-Out 'fable SONNET=sonnet' $fable 'SONNET=cc/claude-sonnet-5'
Assert-Out 'fable HAIKU=haiku' $fable 'HAIKU=cc/claude-haiku-4-5-20251001'

$opus = & "$DIR\9cc.ps1" run opus 2>$null | Out-String
Assert-Out 'opus MODEL' $opus 'MODEL=cc/claude-opus-4-8'
Assert-Out 'opus OPUS' $opus 'OPUS=cc/claude-opus-4-8'
Assert-Out 'opus SONNET=sonnet' $opus 'SONNET=cc/claude-sonnet-5'
Assert-Out 'opus HAIKU' $opus 'HAIKU=cc/claude-haiku-4-5-20251001'

$grok = & "$DIR\9cc.ps1" run grok 2>$null | Out-String
Assert-Out 'grok MODEL' $grok 'MODEL=xai/grok-4.5'
Assert-Out 'grok OPUS' $grok 'OPUS=xai/grok-4.5'
Assert-Out 'grok SONNET' $grok 'SONNET=xai/grok-4.5'
Assert-Out 'grok HAIKU=composer' $grok 'HAIKU=xai/grok-composer-2.5-fast'

$comp = & "$DIR\9cc.ps1" run grokcomposer 2>$null | Out-String
Assert-Out 'composer MODEL' $comp 'MODEL=xai/grok-composer-2.5-fast'
Assert-Out 'composer OPUS=grok' $comp 'OPUS=xai/grok-4.5'
Assert-Out 'composer SONNET=grok' $comp 'SONNET=xai/grok-4.5'
Assert-Out 'composer HAIKU' $comp 'HAIKU=xai/grok-composer-2.5-fast'

$glm = & "$DIR\9cc.ps1" run glm5 2>$null | Out-String
Assert-Out 'glm OPUS=id' $glm 'OPUS=glm/glm-5.2'
Assert-Out 'glm SONNET=id' $glm 'SONNET=glm/glm-5.2'
Assert-Out 'glm HAIKU=id' $glm 'HAIKU=glm/glm-5.2'

$env:PATH = $oldPath
Remove-Item -Recurse -Force $stubDir -ErrorAction SilentlyContinue
Remove-Item -Force $settings -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_SETTINGS -ErrorAction SilentlyContinue

Write-Host "Cycle 6: cascade tiers"
$opus = Get-Cascade 'opus'
if ($opus.Count -eq 3 -and $opus[0] -eq 'cc/claude-opus-4-8') { Write-Host "  ok: opus chain"; $script:Pass++ } else { Write-Host "  FAIL opus: $($opus -join ' ')"; $script:Fail++ }
$free = Get-Cascade 'free'
if ($free.Count -eq 10) { Write-Host "  ok: free 10"; $script:Pass++ } else { Write-Host "  FAIL free count $($free.Count)"; $script:Fail++ }

Write-Host "Cycle 7: Get-NextModel walks + exhausts"
if ((Get-NextModel 'cc/claude-opus-4-8') -eq 'cx/gpt-5.5-high') { Write-Host "  ok: next opus"; $script:Pass++ } else { Write-Host "  FAIL next opus"; $script:Fail++ }
$ex = $null; try { Get-NextModel 'openrouter/nousresearch/hermes-3-llama-3.1-405b:free' -ErrorAction Stop } catch { $ex = $_ }
if ($null -ne $ex) { Write-Host "  ok: exhausted throws"; $script:Pass++ } else { Write-Host "  FAIL: exhausted should throw"; $script:Fail++ }

Write-Host "Cycle 8: List-Models -Json"
$j = List-Models -Json | ConvertFrom-Json
if ($j.Count -eq 13 -and $j[0].alias -eq 'fable') { Write-Host "  ok: json 13"; $script:Pass++ } else { Write-Host "  FAIL json"; $script:Fail++ }

Write-Host "Cycle 9: update command"

$env:CC9_LATEST_API_FIXTURE = "$env:TEMP\9cc-latest-up.json"
'{"tag_name":"v0.1.0"}' | Out-File $env:CC9_LATEST_API_FIXTURE
$env:CC9_VERSION = 'v0.1.0'
$out = & "$DIR\9cc.ps1" update 2>&1
if ($out -eq '9cc is up to date (v0.1.0)') { Write-Host "  ok: up-to-date"; $script:Pass++ } else { Write-Host "  FAIL: up-to-date output was $out"; $script:Fail++ }

$env:CC9_LATEST_API_FIXTURE = "$env:TEMP\9cc-latest-new.json"
'{"tag_name":"v0.2.0"}' | Out-File $env:CC9_LATEST_API_FIXTURE
$env:CC9_VERSION = 'v0.1.0'
$instDir = Join-Path $env:TEMP '9cc-update-install'
New-Item -ItemType Directory -Force $instDir | Out-Null
@'
Write-Host "INSTALLER_RAN version=$env:CC9_VERSION"
'@ | Out-File (Join-Path $instDir 'install.ps1')
$env:CC9_INSTALL_SOURCE = Join-Path $instDir 'install.ps1'
$out = & "$DIR\9cc.ps1" update *>&1
if ($out -match "INSTALLER_RAN version=v0.2.0" -and $out -match "9cc updated to v0.2.0") { Write-Host "  ok: update runs installer"; $script:Pass++ } else { Write-Host "  FAIL: update output was $out"; $script:Fail++ }

$env:CC9_LATEST_API_FIXTURE = "$env:TEMP\no-such-fixture-9cc.json"
$err = $null
try { & "$DIR\9cc.ps1" update *>&1 | Out-Null } catch { $err = $_ }
if ($err -and $err -match "9cc update: failed to reach GitHub") { Write-Host "  ok: API failure reported"; $script:Pass++ } else { Write-Host "  FAIL: API failure not reported"; $script:Fail++ }

Remove-Item $env:CC9_LATEST_API_FIXTURE -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP '9cc-latest-up.json') -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP '9cc-latest-new.json') -ErrorAction SilentlyContinue
Remove-Item $instDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:CC9_LATEST_API_FIXTURE, Env:CC9_VERSION -ErrorAction SilentlyContinue

Write-Host "Cycle 10: uninstall command"
$env:CC9_VERSION = 'v0.3.5'
$env:CC9_HOME   = Join-Path $env:TEMP '9cc-uninstall-home'
$env:CC9_BIN_DIR = Join-Path $env:TEMP '9cc-uninstall-bin'
Remove-Item -Recurse -Force $env:CC9_HOME,$env:CC9_BIN_DIR -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $env:CC9_BIN_DIR | Out-Null
$env:CC9_SOURCE = "$DIR\9cc.ps1"
& "$DIR\install.ps1"
if (Test-Path $env:CC9_HOME) { Write-Host "  ok: installed"; $script:Pass++ } else { Write-Host "  FAIL: not installed"; $script:Fail++ }
& "$DIR\9cc.ps1" uninstall 2>&1 | Out-Null
if (-not (Test-Path $env:CC9_HOME)) { Write-Host "  ok: home removed"; $script:Pass++ } else { Write-Host "  FAIL: home still exists"; $script:Fail++ }
if (-not (Test-Path (Join-Path $env:CC9_BIN_DIR '9cc.ps1'))) { Write-Host "  ok: bin copy removed"; $script:Pass++ } else { Write-Host "  FAIL: bin copy still exists"; $script:Fail++ }
Remove-Item -Recurse -Force $env:CC9_HOME,$env:CC9_BIN_DIR -ErrorAction SilentlyContinue
Remove-Item Env:CC9_SOURCE,Env:CC9_HOME,Env:CC9_BIN_DIR -ErrorAction SilentlyContinue

Write-Host "Cycle 11: install.ps1 prefers gh contents for remote source"
$src = Get-Content -Raw "$DIR\install.ps1"
if ($src -match 'contents/9cc/9cc\.ps1' -and $src -match 'Get-Command gh' -and $src -match 'raw\.githubusercontent\.com') {
    Write-Host "  ok: install.ps1 has gh contents + raw fallback"; $script:Pass++
} else {
    Write-Host "  FAIL: install.ps1 missing gh-first body fetch"; $script:Fail++
}

Write-Host "Cycle 12: Get-LatestTag prefers gh"
$fn = (Get-Content -Raw "$DIR\9cc.ps1")
if ($fn -match 'function Get-LatestTag' -and $fn -match "Get-Command gh") {
    # ensure gh appears inside Get-LatestTag region roughly: between function and next function
    $m = [regex]::Match($fn, 'function Get-LatestTag[\s\S]*?function Update-9cc')
    if ($m.Success -and $m.Value -match 'Get-Command gh') {
        Write-Host "  ok: Get-LatestTag uses gh"; $script:Pass++
    } else { Write-Host "  FAIL: Get-LatestTag missing gh"; $script:Fail++ }
} else { Write-Host "  FAIL: Get-LatestTag missing gh"; $script:Fail++ }

Write-Host "----"
Write-Host "PASS=$script:Pass FAIL=$script:Fail"
if ($script:Fail -ne 0) { exit 1 }
