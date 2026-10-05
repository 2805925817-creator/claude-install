# 可选联网检查：下载并校验所有源的 x64/ARM64 MSI，不安装 Node 或修改 PATH。
param([string]$Version)
$ErrorActionPreference = 'Stop'
$installerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'install.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Download-WithRetry', 'Get-NodeDownloadSources', 'Get-LatestNode24Version', 'Download-NodePackage')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    Invoke-Expression $definition.Extent.Text
}
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testDirectory = [IO.Path]::GetFullPath((Join-Path $tempParent ('node-download-tests-' + [guid]::NewGuid().ToString('N'))))
if (-not $testDirectory.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($testDirectory) -notlike 'node-download-tests-*') { throw '测试目录不正确' }
New-Item -ItemType Directory -Path $testDirectory | Out-Null
try {
    if (-not $Version) { $Version = Get-LatestNode24Version -Directory $testDirectory -Architecture 'x64' }
    $sources = @(Get-NodeDownloadSources -Version $Version)
    $hashes = @{}
    foreach ($source in $sources) {
        # 单独验证每个源，不能让正常主源掩盖备用源问题。
        $script:smokeSource = $source
        function Get-NodeDownloadSources { param($Version) return @($script:smokeSource) }
        foreach ($architecture in @('x64', 'arm64')) {
            $output = Join-Path $testDirectory "node-$Version-$architecture.msi"
            if (-not (Download-NodePackage -Version $Version -Architecture $architecture -Output $output)) {
                throw "下载或校验失败：$source ($architecture)"
            }
            $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
            if ($hashes.ContainsKey($architecture) -and $hashes[$architecture] -ne $hash) {
                throw "不同源的 $architecture 安装包字节不一致"
            }
            $hashes[$architecture] = $hash
            Write-Host "[OK] $source ($architecture): $hash" -ForegroundColor Green
            Remove-Item -LiteralPath $output -Force
        }
    }
} finally {
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}
Write-Host '[OK] 三个下载源的 x64/ARM64 安装包均已下载，SHA-256 校验通过且跨源一致。' -ForegroundColor Green
