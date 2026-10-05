$ErrorActionPreference = 'Stop'
$installerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'install.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

# 只加载模型相关函数，不执行安装、进程关闭或本机配置写入。
foreach ($name in @('Get-ClaudeModels', 'Select-LatestClaudeModel', 'Update-ClaudeModelMappings')) {
    $definition = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    Invoke-Expression $definition.Extent.Text
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$models = @(
    'claude-fable-5', 'claude-fable-5-1', 'claude-opus-4-8', 'claude-opus-5-5',
    'claude-opus-5-5-thinking', 'claude-sonnet-5', 'claude-sonnet-5-5',
    'claude-haiku-4-5-20251001', 'gpt-5', 'claude-sonnet-99-preview'
) | ForEach-Object { [PSCustomObject]@{ id = $_ } }
$settings = [PSCustomObject]@{
    model = 'opus'
    permissions = [PSCustomObject]@{ allow = @('Read') }
    env = [PSCustomObject]@{ ANTHROPIC_DEFAULT_FABLE_MODEL = 'old-fable'; OTHER_SETTING = 'keep' }
}
Update-ClaudeModelMappings -Settings $settings -Models $models
Assert-True ($settings.env.ANTHROPIC_DEFAULT_FABLE_MODEL -eq 'claude-fable-5-1[1M]') 'Fable 最新版本或 1M 后缀错误'
Assert-True ($settings.env.ANTHROPIC_DEFAULT_FABLE_MODEL_NAME -eq 'claude-fable-5-1') '显示名称包含上下文后缀'
Assert-True ($settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL -eq 'claude-opus-5-5[1M]') 'Opus 版本选择错误'
Assert-True ($settings.env.ANTHROPIC_DEFAULT_SONNET_MODEL -eq 'claude-sonnet-5-5[1M]') 'Sonnet 版本选择错误'
Assert-True ($settings.env.ANTHROPIC_DEFAULT_HAIKU_MODEL -eq 'claude-haiku-4-5-20251001') 'Haiku 不应声明 1M'
Assert-True ($settings.model -eq 'opus' -and $settings.env.OTHER_SETTING -eq 'keep') '其他配置被改变'

$numericModels = @('claude-opus-5-9', 'claude-opus-5-10', 'claude-opus-5-10-thinking') |
    ForEach-Object { [PSCustomObject]@{ id = $_ } }
Assert-True ((Select-LatestClaudeModel $numericModels 'opus').Name -eq 'claude-opus-5-10') '必须按数字排序版本'
$legacy = @('claude-3-haiku-20240307', 'claude-3-5-haiku-20241022') |
    ForEach-Object { [PSCustomObject]@{ id = $_ } }
Assert-True ((Select-LatestClaudeModel $legacy 'haiku').Name -eq 'claude-3-5-haiku-20241022') '旧版命名解析错误'
$dated = @('claude-sonnet-4-6-20260101', 'claude-sonnet-4-6-20260201') |
    ForEach-Object { [PSCustomObject]@{ id = $_ } }
Assert-True ((Select-LatestClaudeModel $dated 'sonnet').Name -eq 'claude-sonnet-4-6-20260201') '同版本发布日期排序错误'
Assert-True (-not (Select-LatestClaudeModel @([PSCustomObject]@{ id = 'claude-opus-4-5' }) 'opus').Supports1M) '旧 Opus 不应声明 1M'
$suffixed = Select-LatestClaudeModel @([PSCustomObject]@{ id = 'claude-fable-5-1[1m]' }) 'fable'
Assert-True ($suffixed.Name -eq 'claude-fable-5-1') '重复上下文后缀未移除'
$before = $settings.env.ANTHROPIC_DEFAULT_FABLE_MODEL
Update-ClaudeModelMappings -Settings $settings -Models @([PSCustomObject]@{ id = 'claude-opus-5-5' })
Assert-True ($settings.env.ANTHROPIC_DEFAULT_FABLE_MODEL -eq $before) '缺失系列的原配置未保留'

# 模拟模型列表 API，包括分页、格式错误和网络失败。
$script:mode = 'success'
$script:requests = @()
function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $TimeoutSec, $ErrorAction)
    Assert-True ($Headers.Authorization -eq 'Bearer test-token') '请求没有使用本次输入的 Token'
    $script:requests += $Uri
    switch ($script:mode) {
        'failure' { throw '模拟网络失败' }
        'empty' { return [PSCustomObject]@{ data = @() } }
        'rejected' { return [PSCustomObject]@{ success = $false; data = $script:models } }
        'pagination' {
            if ($Uri -match 'after_id=') { return [PSCustomObject]@{ data = @($script:models[1]); has_more = $false } }
            return [PSCustomObject]@{ data = @($script:models[0]); has_more = $true; last_id = 'model/one' }
        }
        'bad-pagination' { return [PSCustomObject]@{ data = @($script:models[0]); has_more = $true } }
        default { return [PSCustomObject]@{ data = $script:models; success = $true } }
    }
}
Assert-True (@(Get-ClaudeModels 'https://tdyun.ai/' 'test-token').Count -eq $models.Count) '模型列表解析错误'
Assert-True ($script:requests[0] -eq 'https://tdyun.ai/v1/models') 'API URL 拼接错误'
$script:mode = 'pagination'
$script:requests = @()
Assert-True (@(Get-ClaudeModels 'https://tdyun.ai' 'test-token').Count -eq 2) '分页未收集完整模型列表'
Assert-True ($script:requests[1] -eq 'https://tdyun.ai/v1/models?after_id=model%2Fone') '分页游标未编码'
foreach ($mode in @('failure', 'empty', 'rejected', 'bad-pagination')) {
    $script:mode = $mode
    $failed = $false
    try { Get-ClaudeModels 'https://tdyun.ai' 'test-token' | Out-Null } catch { $failed = $true }
    Assert-True $failed "错误响应未被处理：$mode"
}

# 在独立临时目录验证真实配置写入段，不触碰用户配置。
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testSettingsDir = Join-Path $tempRoot ('claude-model-tests-' + [guid]::NewGuid().ToString('N'))
$source = Get-Content -LiteralPath $installerPath -Raw -Encoding UTF8
$start = $source.IndexOf('# 写入 settings.json')
$end = $source.IndexOf('# 6. 启动 claude', $start)
$configBlock = $source.Substring($start, $end - $start).Replace(
    '$settingsDir = "$env:USERPROFILE\.claude"', '$settingsDir = $testSettingsDir')
$baseUrl = 'https://tdyun.ai'
$token = 'test-token'
$gitBash = 'C:\Test Git\bin\bash.exe'
try {
    $script:mode = 'success'
    Invoke-Expression $configBlock
    $file = Join-Path $testSettingsDir 'settings.json'
    $written = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($written.env.ANTHROPIC_DEFAULT_FABLE_MODEL -eq 'claude-fable-5-1[1M]') '全新配置未写入模型'
    Assert-True ($written.env.CLAUDE_CODE_GIT_BASH_PATH -eq $gitBash) 'Git Bash 路径未保存到配置'

    $written | Add-Member -NotePropertyName model -NotePropertyValue 'claude-opus-4-8' -Force
    $written.env | Add-Member -NotePropertyName ANTHROPIC_MODEL -NotePropertyValue 'sonnet' -Force
    $written.env.ANTHROPIC_BASE_URL = 'https://old.example'
    $written.env.ANTHROPIC_AUTH_TOKEN = 'old-token'
    $written | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file -Encoding UTF8
    $script:mode = 'failure'
    Invoke-Expression $configBlock
    $written = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($written.env.ANTHROPIC_BASE_URL -eq $baseUrl -and $written.env.ANTHROPIC_AUTH_TOKEN -eq $token) 'API 配置未覆盖'
    Assert-True ($written.model -eq 'claude-opus-4-8' -and $written.env.ANTHROPIC_MODEL -eq 'sonnet') '原模型选择被改变'
    Assert-True ($written.env.ANTHROPIC_DEFAULT_FABLE_MODEL -eq 'claude-fable-5-1[1M]') '请求失败时丢失旧映射'

    Set-Content -LiteralPath $file -Value '{broken json' -Encoding UTF8
    $before = Get-Content -LiteralPath $file -Raw
    $failed = $false
    try { Invoke-Expression $configBlock } catch { $failed = $true }
    Assert-True ($failed -and (Get-Content -LiteralPath $file -Raw) -eq $before) '无效 JSON 被覆盖'
} finally {
    $resolved = [System.IO.Path]::GetFullPath($testSettingsDir)
    if (-not $resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.IO.Path]::GetFileName($resolved) -notlike 'claude-model-tests-*') {
        throw '临时目录路径不正确，停止清理'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host '[OK] 模型选择、分页、配置保留和失败处理验证全部通过。' -ForegroundColor Green
