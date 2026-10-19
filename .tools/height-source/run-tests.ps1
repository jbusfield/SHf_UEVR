$ErrorActionPreference = 'Stop'
$taskDir = $PSScriptRoot
$projectDir = Split-Path (Split-Path $taskDir)
$sourceFiles = [ordered]@{
    input = Join-Path $projectDir 'scripts/libs/input.lua'
    original = Join-Path $taskDir 'input.original.lua'
    preopt = Join-Path $taskDir 'input.pre-opt.lua'
    preMesh = Join-Path $taskDir 'input.pre-mesh-opt.lua'
    meshTests = Join-Path $taskDir 'mesh-tests.lua'
    ui = Join-Path $projectDir 'scripts/libs/config/input_config_dev.lua'
    enums = Join-Path $projectDir 'scripts/libs/enums/input.lua'
}
$code = "local sources = {} `n"
foreach ($entry in $sourceFiles.GetEnumerator()) {
    $sourceText = [IO.File]::ReadAllText($entry.Value)
    if ($sourceText.Contains(']====]')) { throw 'Unexpected Lua long-string delimiter' }
    $code += "sources.$($entry.Key) = [====[$sourceText]====] `n"
}
$code += [IO.File]::ReadAllText((Join-Path $taskDir 'test.lua'))
$body = @{code = $code; timeout = 10000} | ConvertTo-Json -Compress
$result = Invoke-RestMethod -Uri 'http://localhost:8899/api/lua/exec' -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body))
$result | ConvertTo-Json -Depth 10
if (-not $result.success) { throw 'Height source tests failed' }
