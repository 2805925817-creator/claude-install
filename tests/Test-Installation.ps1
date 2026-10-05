$ErrorActionPreference = 'Stop'
$installerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'install.ps1'
$source = Get-Content -LiteralPath $installerPath -Raw -Encoding UTF8
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($definition in $ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true)) { Invoke-Expression $definition.Extent.Text }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Fails {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-True ($caught -and $caught -match $Pattern) "未按预期停止：$Pattern；实际：$caught"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('claude-install-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$savedPath = $env:Path
$savedBash = $env:CLAUDE_CODE_GIT_BASH_PATH
$savedArchitecture = $env:PROCESSOR_ARCHITECTURE
$savedNativeArchitecture = $env:PROCESSOR_ARCHITEW6432
try {
    # 管理员入口必须在读取 Token、安装和配置写入前停止；32 位宿主按原生架构选包。
    & {
        function Test-IsAdministrator { return $script:isAdministrator }
        function Refresh-Path { }
        $start = $source.IndexOf('# 由实际使用 Claude 的用户运行')
        $end = $source.IndexOf('$token = Read-Host', $start)
        $preflight = $source.Substring($start, $end - $start)
        $script:isAdministrator = $true
        Assert-Fails { Invoke-Expression $preflight } '普通权限'
        $script:isAdministrator = $false
        $env:PROCESSOR_ARCHITECTURE = 'x86'
        $env:PROCESSOR_ARCHITEW6432 = 'AMD64'
        Invoke-Expression $preflight
        Assert-True ($nodeArch -eq 'x64' -and $gitArch -eq '64-bit') '32 位 PowerShell 选错系统架构'
        $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
        Invoke-Expression $preflight
        Assert-True ($nodeArch -eq 'arm64' -and $gitArch -eq 'arm64') 'ARM64 选包错误'
        $env:PROCESSOR_ARCHITEW6432 = $null
        Assert-Fails { Invoke-Expression $preflight } '不支持的 Windows 架构'
    }
    # 验证真实命令探测：同名损坏命令、错误输出、退出码失败都不算成功。
    & {
        $script:testCommandPath = Join-Path $testRoot 'probe.cmd'
        function Get-Command { param($Name, $CommandType, [switch]$All, $ErrorAction)
            [PSCustomObject]@{ Source = $script:testCommandPath }
        }
        Set-Content -LiteralPath $script:testCommandPath -Encoding ASCII -Value "@echo off`r`necho 2.1.0 (Claude Code)`r`nexit /b 1"
        Assert-True ($null -eq (Get-WorkingCommand @('claude.cmd') '^(\d+\.\d+\.\d+).*\(Claude Code\)')) '损坏 Claude 被判成功'
        Set-Content -LiteralPath $script:testCommandPath -Encoding ASCII -Value "@echo off`r`necho not-claude`r`nexit /b 0"
        Assert-True ($null -eq (Get-WorkingCommand @('claude.cmd') '^(\d+\.\d+\.\d+).*\(Claude Code\)')) '错误程序被判成功'
        Set-Content -LiteralPath $script:testCommandPath -Encoding ASCII -Value "@echo off`r`necho 2.1.0 (Claude Code)`r`nexit /b 0"
        Assert-True ((Get-WorkingCommand @('claude.cmd') '^(\d+\.\d+\.\d+).*\(Claude Code\)').Version -eq '2.1.0') '正常 Claude 验证失败'
    }

    & {
        function Get-WorkingCommand { param($Names, $VersionPattern)
            if ($Names[0] -eq 'node.exe' -and $script:nodeVersion) {
                return [PSCustomObject]@{ Path = 'C:\Node\node.exe'; Version = $script:nodeVersion }
            }
            if ($Names[0] -eq 'npm.cmd' -and $script:hasNpm) {
                return [PSCustomObject]@{ Path = 'C:\Node\npm.cmd'; Version = '10.9.0' }
            }
        }
        foreach ($scenario in @(
            @{ Version = '18.20.0'; Npm = $true; Ready = $false },
            @{ Version = '22.15.0'; Npm = $false; Ready = $false },
            @{ Version = $null; Npm = $true; Ready = $false },
            @{ Version = '22.15.0'; Npm = $true; Ready = $true },
            @{ Version = '24.0.0'; Npm = $true; Ready = $true }
        )) {
            $script:nodeVersion = $scenario.Version
            $script:hasNpm = $scenario.Npm
            Assert-True ((Get-NodeEnvironment).Ready -eq $scenario.Ready) 'Node/npm 就绪判断错误'
        }
    }

    # 模拟 HTTP 错误写入错误页：必须拒绝该文件，并保留超时参数。
    & {
        $script:curlMode = 'failure'
        $script:curlCalls = 0
        function curl.exe {
            $script:curlCalls++
            Assert-True ($args -contains '--fail' -and $args -contains '--connect-timeout' -and $args -contains '--max-time' -and $args -contains '--speed-limit' -and $args -contains '--speed-time') '下载没有 HTTP/超时/低速防护'
            $output = $args[[Array]::IndexOf($args, '-o') + 1]
            Set-Content -LiteralPath $output -Value 'error-page'
            $global:LASTEXITCODE = if ($script:curlMode -eq 'failure') { 22 } else { 0 }
        }
        function Start-Sleep { param($Seconds) }
        $output = Join-Path $testRoot 'download.bin'
        Assert-True (-not (Download-WithRetry 'https://test.invalid/file' $output)) 'HTTP 错误被接受'
        Assert-True ($script:curlCalls -eq 3 -and -not (Test-Path -LiteralPath $output)) '重试或失败文件清理错误'
        $script:curlMode = 'success'
        Assert-True (Download-WithRetry 'https://test.invalid/file' $output) '正常下载被拒绝'
    }

    # Node 下载：主源故障、校验页错误、损坏包、官方回退和全部失败。
    $fixture = Join-Path $testRoot 'valid-package.bin'
    Set-Content -LiteralPath $fixture -Value 'valid-package' -NoNewline -Encoding ASCII
    $script:packageHash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
    foreach ($scenario in @('first-good', 'first-http', 'checksum-http', 'corrupt', 'missing-checksum', 'official-only', 'all-fail')) {
        & {
            $script:downloadCalls = @()
            $script:nodeSources = @(Get-NodeDownloadSources 'v22.15.0')
            Assert-True ($script:nodeSources.Count -eq 3 -and
                ([uri]$script:nodeSources[0]).Host -eq 'cdn.npmmirror.com' -and
                ([uri]$script:nodeSources[1]).Host -eq 'mirrors.huaweicloud.com' -and
                ([uri]$script:nodeSources[2]).Host -eq 'nodejs.org') '国内优先或独立备用源不正确'
            $architecture = if ($scenario -eq 'official-only') { 'arm64' } else { 'x64' }
            $script:expectedFileName = "node-v22.15.0-$architecture.msi"
            function Download-WithRetry {
                param($Url, $Output, $MaxRetries, $ConnectTimeout, $MaxTime)
                $script:downloadCalls += $Url
                Assert-True ($MaxRetries -eq 1 -and $ConnectTimeout -eq 10) '故障源仍反复重试或连接等待过长'
                $sourceIndex = [Array]::IndexOf($script:nodeSources, $Url.Substring(0, $Url.LastIndexOf('/')))
                Assert-True ($sourceIndex -ge 0) '下载 URL 不属于已配置源'
                if ($Url.EndsWith('/SHASUMS256.txt')) {
                    Assert-True ($MaxTime -eq 30) '校验文件等待过长'
                    if ($scenario -eq 'checksum-http' -and $sourceIndex -eq 0) { return $false }
                    $fileName = if ($scenario -eq 'missing-checksum' -and $sourceIndex -eq 0) { 'other-version.msi' } else { $script:expectedFileName }
                    Set-Content -LiteralPath $Output -Encoding ASCII -Value ($script:packageHash + '  ' + $fileName)
                    return $true
                }
                Assert-True ($MaxTime -eq 180 -and $Url.EndsWith('/' + $script:expectedFileName)) '安装包超时或版本/架构不正确'
                if ($scenario -eq 'all-fail' -or
                    ($scenario -eq 'first-http' -and $sourceIndex -eq 0) -or
                    ($scenario -eq 'official-only' -and $sourceIndex -lt 2)) {
                    Set-Content -LiteralPath $Output -Value 'partial-package' -Encoding ASCII
                    return $false
                }
                $content = if ($scenario -eq 'corrupt' -and $sourceIndex -eq 0) { 'corrupt-package' } else { 'valid-package' }
                Set-Content -LiteralPath $Output -Value $content -NoNewline -Encoding ASCII
                return $true
            }
            $output = Join-Path $testRoot ("$scenario.msi")
            $success = Download-NodePackage -Version 'v22.15.0' -Architecture $architecture -Output $output
            Assert-True ($success -eq ($scenario -ne 'all-fail')) '多源下载结果不正确'
            Assert-True (-not (Test-Path -LiteralPath "$output.sha256")) '校验临时文件没有清理'
            if ($success) {
                Assert-True ((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash -eq $script:packageHash) '损坏安装包被接受'
                $lastSource = $script:downloadCalls[-1].Substring(0, $script:downloadCalls[-1].LastIndexOf('/'))
                $expectedSourceIndex = if ($scenario -eq 'first-good') { 0 } elseif ($scenario -eq 'official-only') { 2 } else { 1 }
                Assert-True ($lastSource -eq $script:nodeSources[$expectedSourceIndex]) '没有切换到正确备用源或成功后仍继续下载'
            } else {
                Assert-True (-not (Test-Path -LiteralPath $output) -and $script:downloadCalls.Count -eq 6) '全部失败后保留了半包或没有尝试全部来源'
            }
        }
    }

    # 安装码，包括 Windows MSI 需要重启的成功码与取消/并发安装失败。
    & {
        function Test-IsAdministrator { return $false }
        function Start-Process {
            param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $ErrorAction, $Verb)
            Assert-True ($Wait -and $PassThru) '没有等待安装并取得退出码'
            Assert-True ($Verb -eq 'RunAs') '依赖安装没有单独请求 UAC 提权'
            if ($script:cancelUac) { throw 'UAC canceled' }
            [PSCustomObject]@{ ExitCode = $script:installerCode }
        }
        $script:cancelUac = $false
        foreach ($code in @(0, 3010)) {
            $script:installerCode = $code
            Invoke-Installer 'fake.msi' '/qn' 'Node.js' @(0, 3010)
        }
        foreach ($code in @(1603, 1618, 1602)) {
            $script:installerCode = $code
            Assert-Fails { Invoke-Installer 'fake.msi' '/qn' 'Node.js' @(0, 3010) } ([string]$code)
        }
        $script:cancelUac = $true
        Assert-Fails { Invoke-Installer 'fake.exe' '/silent' 'Git' } 'UAC'
    }

    # Bash 必须真实响应，不能只因文件存在就认为可用。
    & {
        $env:CLAUDE_CODE_GIT_BASH_PATH = 'Test-Bash'
        function Test-Path { param($LiteralPath, $PathType) return $LiteralPath -eq 'Test-Bash' }
        function Test-Bash {
            $global:LASTEXITCODE = $script:bashCode
            return $script:bashOutput
        }
        $script:bashCode = 1; $script:bashOutput = 'git-bash-ok'
        Assert-True ($null -eq (Find-GitBash 'C:\Custom\Git\cmd\git.exe')) '损坏 Bash 被接受'
        $script:bashCode = 0
        Assert-True ((Find-GitBash 'C:\Custom\Git\cmd\git.exe') -eq 'Test-Bash') '自定义 Bash 未被识别'
        $script:bashOutput = 'wrong shell'
        Assert-True ($null -eq (Find-GitBash 'C:\Custom\Git\cmd\git.exe')) '错误 Bash 输出被接受'
    }

    Assert-True ((Merge-PathEntry 'C:\Existing;C:\Custom Npm\' 'c:\custom npm') -eq 'C:\Existing;C:\Custom Npm\') 'PATH 重复添加'
    Assert-True ((Merge-PathEntry 'C:\Existing' 'C:\Custom Npm') -eq 'C:\Existing;C:\Custom Npm') '自定义 prefix 未保留或破坏原 PATH'

    # 执行真实依赖安装分支；所有外部安装和下载均被替换。
    $dependencyStart = $source.IndexOf('# Git 和 Node.js 安装包共用')
    $dependencyEnd = $source.IndexOf('# 3. ', $dependencyStart)
    $dependencyBlock = $source.Substring($dependencyStart, $dependencyEnd - $dependencyStart)
    foreach ($scenario in @('missing-bash', 'old-node', 'missing-npm-new-node', 'download-failure', 'postcheck-failure')) {
        & {
            $script:gitReady = $scenario -ne 'missing-bash'
            $script:nodeReady = $scenario -eq 'missing-bash'
            $script:installCalls = @()
            $nodeArch = 'arm64'; $gitArch = 'arm64'
            function Get-WorkingCommand { param($Names, $VersionPattern)
                [PSCustomObject]@{ Path = 'C:\Git\cmd\git.exe'; Version = '2.47.1' }
            }
            function Find-GitBash { param($GitPath)
                if ($script:gitReady) { return 'C:\Git\bin\bash.exe' }
            }
            function Get-NodeEnvironment {
                $version = if ($scenario -eq 'missing-npm-new-node') { '24.0.0' } elseif ($script:nodeReady) { '22.15.0' } else { '18.20.0' }
                [PSCustomObject]@{ Node = [PSCustomObject]@{ Path = 'C:\Node\node.exe'; Version = $version }; Npm = [PSCustomObject]@{ Version = '10.9.0' }; Ready = $script:nodeReady }
            }
            function Download-WithRetry { param($Url, $Output)
                $script:downloadUrl = $Url
                $script:dependencyTempDir = Split-Path $Output -Parent
                return $scenario -ne 'download-failure'
            }
            function Download-NodePackage { param($Version, $Architecture, $Output)
                $script:downloadUrl = "https://test.invalid/$Version/node-$Version-$Architecture.msi"
                $script:dependencyTempDir = Split-Path $Output -Parent
                return $scenario -ne 'download-failure'
            }
            function Invoke-Installer { param($FilePath, $Arguments, $Name, $SuccessCodes)
                $script:installCalls += $Name
                $script:installerArgs = $Arguments
                if ($Name -eq 'Git') { $script:gitReady = $true }
                if ($Name -eq 'Node.js' -and $scenario -ne 'postcheck-failure') { $script:nodeReady = $true }
            }
            function Refresh-Path { }
            if ($scenario -eq 'download-failure') {
                Assert-Fails { Invoke-Expression $dependencyBlock } '下载失败'
                Assert-True ($script:installCalls.Count -eq 0) '下载失败后仍安装'
            } elseif ($scenario -eq 'postcheck-failure') {
                Assert-Fails { Invoke-Expression $dependencyBlock } '安装后验证失败'
            } else {
                Invoke-Expression $dependencyBlock
                Assert-True ($script:installCalls.Count -eq 1) '依赖修复分支不正确'
                if ($scenario -eq 'missing-bash') {
                    Assert-True ($script:installCalls[0] -eq 'Git' -and $script:installerArgs -match '/ALLUSERS') '缺 Bash 未安装完整 Git'
                }
                if ($scenario -eq 'missing-npm-new-node') {
                    Assert-True ($script:downloadUrl -match 'v24.0.0.*arm64' -and $script:installerArgs -match 'REINSTALL=ALL') 'npm 修复降级 Node 或架构错误'
                }
            }
            Assert-True (-not (Test-Path -LiteralPath $script:dependencyTempDir)) '失败或成功后未清理临时目录'
        }
    }

    # 验证 npm 失败及时停止，自定义 prefix 可找到已有或修复后的 Claude。
    $claudeStart = $source.IndexOf('# 3. ')
    $claudeEnd = $source.IndexOf('# 5. ', $claudeStart)
    $claudeBlock = $source.Substring($claudeStart, $claudeEnd - $claudeStart)
    foreach ($scenario in @('existing', 'repair', 'npm-failure', 'broken-after-install', 'prefix-failure')) {
        & {
            $script:claudeReady = $scenario -eq 'existing'
            $script:npmInstalls = 0
            $script:pathAdded = $null
            $nodeEnvironment = [PSCustomObject]@{ Npm = [PSCustomObject]@{ Path = 'Test-Npm' } }
            function Test-Npm {
                if ($args[0] -eq 'prefix') {
                    $global:LASTEXITCODE = if ($scenario -eq 'prefix-failure') { 1 } else { 0 }
                    return 'C:\Custom Npm'
                }
                Assert-True ($args -contains '--registry=https://registry.npmmirror.com') 'npm 源不再仅对本次生效'
                $script:npmInstalls++
                $global:LASTEXITCODE = if ($scenario -eq 'npm-failure') { 1 } else { 0 }
                $script:claudeReady = $scenario -ne 'broken-after-install'
            }
            function Get-WorkingCommand { param($Names, $VersionPattern)
                Assert-True ($env:Path.StartsWith('C:\Custom Npm;')) '验证前未加入自定义 prefix'
                if ($script:claudeReady) { [PSCustomObject]@{ Path = 'C:\Custom Npm\claude.cmd'; Version = '2.1.0' } }
            }
            function Add-UserPath { param($Directory) $script:pathAdded = $Directory }
            switch ($scenario) {
                'npm-failure' { Assert-Fails { Invoke-Expression $claudeBlock } 'npm 安装失败' }
                'broken-after-install' { Assert-Fails { Invoke-Expression $claudeBlock } '--version' }
                'prefix-failure' { Assert-Fails { Invoke-Expression $claudeBlock } '全局安装目录' }
                default {
                    Invoke-Expression $claudeBlock
                    Assert-True ($script:pathAdded -eq 'C:\Custom Npm') '未持久化自定义 PATH'
                    Assert-True ($script:npmInstalls -eq [int]($scenario -eq 'repair')) '已有 Claude 被重复安装或损坏命令未修复'
                }
            }
            if ($scenario -match 'failure|broken') { Assert-True ($null -eq $script:pathAdded) '失败时仍报告安装成功' }
        }
    }
} finally {
    $env:Path = $savedPath
    $env:CLAUDE_CODE_GIT_BASH_PATH = $savedBash
    $env:PROCESSOR_ARCHITECTURE = $savedArchitecture
    $env:PROCESSOR_ARCHITEW6432 = $savedNativeArchitecture
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'claude-install-tests-*') { throw '测试目录不正确，停止清理' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host '[OK] 安装检测、下载失败、退出码、Git Bash、Node/npm 修复和自定义 PATH 场景全部通过。' -ForegroundColor Green
