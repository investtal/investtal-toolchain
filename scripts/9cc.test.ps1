# 9cc.ps1 TDD harness. Assert-based. Run: pwsh -File scripts/9cc.test.ps1
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

Write-Host "----"
Write-Host "PASS=$script:Pass FAIL=$script:Fail"
if ($script:Fail -ne 0) { exit 1 }
