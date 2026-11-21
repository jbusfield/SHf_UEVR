$ErrorActionPreference = 'Stop'
$projectDir = Split-Path (Split-Path $PSScriptRoot)
$ikSource = [IO.File]::ReadAllText((Join-Path $projectDir 'scripts/libs/ik.lua'))
$inputSource = [IO.File]::ReadAllText((Join-Path $projectDir 'scripts/libs/input.lua'))
$tests = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'test.lua'))
$utilsSource = [IO.File]::ReadAllText((Join-Path $projectDir 'scripts/libs/uevr_utils.lua'))
$code = "local tests = [====[$tests]====]`nlocal ikSource = [====[$ikSource]====]`nlocal inputSource = [====[$inputSource]====]`nlocal utilsSource = [====[$utilsSource]====]`nreturn assert(load(tests, '@snap-turn/test.lua', 't', _ENV))(ikSource, inputSource, utilsSource)"
$body = @{code = $code; timeout = 10000} | ConvertTo-Json -Compress
$result = Invoke-RestMethod -Uri 'http://localhost:8899/api/lua/exec' -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body))
$result | ConvertTo-Json -Depth 10
if (-not $result.success) { throw 'Snap-turn checks failed' }
