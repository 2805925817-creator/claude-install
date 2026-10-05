$baseUrl = "https://tdyun.ai"
$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

Write-Host "========================================"
Write-Host "  Claude Code 一键安装脚本"
Write-Host "========================================"
Write-Host ""

function Refresh-Path {
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    # 保留启动器、版本管理器等只存在于当前进程的 PATH。
    $env:Path = "$machinePath;$userPath;$env:Path"
}

function Download-WithRetry {
    param(
        [string]$Url,
        [string]$Output,
        [int]$MaxRetries = 3,
        [int]$ConnectTimeout = 20,
        [int]$MaxTime = 600,
        [int]$LowSpeedTime = 30
    )

    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Host "下载中 (尝试 $i/$MaxRetries)..." -ForegroundColor Yellow
        curl.exe --fail -L --connect-timeout $ConnectTimeout --max-time $MaxTime --speed-limit 1024 --speed-time $LowSpeedTime --progress-bar -o $Output $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Output) -and
            (Get-Item -LiteralPath $Output).Length -gt 0) {
            return $true
        }
        Remove-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue
        if ($i -lt $MaxRetries) {
            Write-Host "下载失败，3秒后重试..." -ForegroundColor Yellow
            Start-Sleep -Seconds 3
        }
    }
    return $false
}

function Get-NodeDownloadSources {
    param([string]$Version)
    # 国内镜像优先；不同运营方提供容灾，最后回退到官方源。
    return @(
        "https://cdn.npmmirror.com/binaries/node/$Version",
        "https://mirrors.huaweicloud.com/nodejs/$Version",
        "https://nodejs.org/dist/$Version"
    )
}

function Get-LatestNode24Version {
    param([string]$Directory, [ValidateSet('x64', 'arm64')][string]$Architecture)
    $manifestPath = Join-Path $Directory 'node24-latest-shasums.txt'
    $sources = @(Get-NodeDownloadSources -Version 'latest-v24.x')
    # 小型版本清单优先官方，防止镜像的 latest 别名滞后；包下载仍优先国内。
    [array]::Reverse($sources)
    try {
        foreach ($source in $sources) {
            Write-Host "正在查询 Node 24 最新正式版：$source" -ForegroundColor Yellow
            if (-not (Download-WithRetry -Url "$source/SHASUMS256.txt" -Output $manifestPath -MaxRetries 1 -ConnectTimeout 8 -MaxTime 15)) {
                continue
            }
            $pattern = '(?im)^[a-f0-9]{64}\s+\*?node-(v24\.\d+\.\d+)-' + [regex]::Escape($Architecture) + '\.msi\s*$'
            $content = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
            $versions = @([regex]::Matches($content, $pattern) | ForEach-Object { $_.Groups[1].Value })
            if ($versions.Count) {
                return ($versions | Sort-Object { [version]$_.Substring(1) } -Descending | Select-Object -First 1)
            }
            Write-Host '[WARN] 版本清单不包含 Node 24 正式版安装包，切换查询源。' -ForegroundColor Yellow
        }
        throw '无法查询 Node 24 最新正式版，请检查网络或代理后重试。'
    } finally {
        Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    }
}

function Download-NodePackage {
    param(
        [ValidatePattern('^v\d+\.\d+\.\d+$')][string]$Version,
        [ValidateSet('x64', 'arm64')][string]$Architecture,
        [string]$Output
    )
    $fileName = "node-$Version-$Architecture.msi"
    $checksumPath = "$Output.sha256"
    try {
        foreach ($source in @(Get-NodeDownloadSources -Version $Version)) {
            Write-Host "正在尝试 Node.js 下载源：$source" -ForegroundColor Yellow
            # 每个源只尝试一次，失败立即换源；小文件限制在 30 秒内。
            if (-not (Download-WithRetry -Url "$source/SHASUMS256.txt" -Output $checksumPath -MaxRetries 1 -ConnectTimeout 10 -MaxTime 30)) {
                Write-Host "[WARN] 无法获取校验信息，切换下一个下载源。" -ForegroundColor Yellow
                continue
            }
            $checksumPattern = '(?im)^([a-f0-9]{64})\s+\*?' + [regex]::Escape($fileName) + '\s*$'
            $checksumText = Get-Content -LiteralPath $checksumPath -Raw -Encoding UTF8
            if ($checksumText -notmatch $checksumPattern) {
                Write-Host "[WARN] 校验信息中没有目标安装包，切换下一个下载源。" -ForegroundColor Yellow
                continue
            }
            $expectedHash = $Matches[1]
            if (-not (Download-WithRetry -Url "$source/$fileName" -Output $Output -MaxRetries 1 -ConnectTimeout 10 -MaxTime 180)) {
                Write-Host "[WARN] 安装包下载失败或超时，切换下一个下载源。" -ForegroundColor Yellow
                continue
            }
            $actualHash = (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash
            if ($actualHash -ieq $expectedHash) {
                Write-Host "[OK] Node.js 安装包 SHA-256 校验通过。" -ForegroundColor Green
                return $true
            }
            Remove-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue
            Write-Host "[WARN] 安装包 SHA-256 不匹配，切换下一个下载源。" -ForegroundColor Yellow
        }
        Remove-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue
        return $false
    } finally {
        Remove-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-WorkingCommand {
    param([string[]]$Names, [string]$VersionPattern)
    foreach ($name in $Names) {
        foreach ($command in @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)) {
            try {
                $output = @(& $command.Source --version 2>&1)
                if ($LASTEXITCODE -eq 0 -and ($output -join "`n") -match $VersionPattern) {
                    return [PSCustomObject]@{ Path = $command.Source; Version = $Matches[1] }
                }
            } catch { }
        }
    }
    return $null
}

function Get-NodeEnvironment {
    $node = Get-WorkingCommand -Names @('node.exe') -VersionPattern '^v(\d+\.\d+\.\d+)\s*$'
    if ($node) {
        # npm 的子进程也必须使用刚刚验证过的 Node，而不是 PATH 中更靠前的损坏版本。
        $env:Path = "$(Split-Path $node.Path -Parent);$env:Path"
    }
    $npm = Get-WorkingCommand -Names @('npm.cmd') -VersionPattern '^(\d+\.\d+\.\d+)\s*$'
    return [PSCustomObject]@{ Node = $node; Npm = $npm; Ready = (
        $null -ne $node -and [version]$node.Version -ge [version]'22.0.0' -and $null -ne $npm
    ) }
}

function Find-GitBash {
    param([string]$GitPath)
    $candidates = @($env:CLAUDE_CODE_GIT_BASH_PATH)
    if ($GitPath) {
        $root = Split-Path $GitPath -Parent
        for ($level = 0; $level -lt 3 -and $root; $level++) {
            $candidates += Join-Path $root 'bin\bash.exe'
            $candidates += Join-Path $root 'usr\bin\bash.exe'
            $root = Split-Path $root -Parent
        }
    }
    foreach ($location in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($location) {
            $candidates += Join-Path $location 'Git\bin\bash.exe'
            $candidates += Join-Path $location 'Programs\Git\bin\bash.exe'
        }
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            try {
                $output = @(& $candidate --noprofile --norc -c 'printf git-bash-ok' 2>&1)
                if ($LASTEXITCODE -eq 0 -and ($output -join '') -eq 'git-bash-ok') { return $candidate }
            } catch { }
        }
    }
    return $null
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Installer {
    param([string]$FilePath, [string]$Arguments, [string]$Name, [int[]]$SuccessCodes = @(0))
    $options = @{ FilePath = $FilePath; ArgumentList = $Arguments; Wait = $true; PassThru = $true; ErrorAction = 'Stop' }
    if (-not (Test-IsAdministrator)) {
        # 只提权系统安装包；当前脚本、npm 和配置写入仍由原用户运行。
        $options.Verb = 'RunAs'
    }
    try { $process = Start-Process @options } catch {
        throw "$Name 安装程序未能启动（可能取消了 UAC 授权）：$($_.Exception.Message)"
    }
    if ($process.ExitCode -notin $SuccessCodes) {
        throw "$Name 安装失败，退出码 $($process.ExitCode)。请检查权限、安装包或其他正在运行的安装程序。"
    }
    if ($process.ExitCode -eq 3010) {
        Write-Host "[WARN] $Name 安装完成，但 Windows 要求重新启动。" -ForegroundColor Yellow
    }
}

function Get-NpmPrefix {
    param([string]$NpmPath)
    $output = @(& $NpmPath prefix -g 2>&1)
    if ($LASTEXITCODE -ne 0) { throw '无法获取 npm 全局安装目录，请修复 npm 配置。' }
    $prefix = ($output -join "`n").Trim()
    if (-not $prefix -or -not [System.IO.Path]::IsPathRooted($prefix) -or $prefix.Contains("`n")) {
        throw 'npm 返回的全局安装目录不正确。'
    }
    return $prefix
}

function Merge-PathEntry {
    param([string]$PathValue, [string]$Directory)
    $entries = @($PathValue -split ';' | Where-Object { $_ })
    if (-not ($entries | Where-Object {
        [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $Directory.TrimEnd('\')
    })) {
        return ($entries + $Directory) -join ';'
    }
    return $PathValue
}

function Add-UserPath {
    param([string]$Directory)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $newPath = Merge-PathEntry -PathValue $userPath -Directory $Directory
    if ($newPath -ne $userPath) { [Environment]::SetEnvironmentVariable('Path', $newPath, 'User') }
    $env:Path = "$Directory;$env:Path"
}

function Get-ClaudeModels {
    param([string]$BaseUrl, [string]$Token)

    $endpoint = $BaseUrl.TrimEnd('/') + '/v1/models'
    $headers = @{ Authorization = "Bearer $Token"; 'anthropic-version' = '2023-06-01' }
    $models = @()
    $lastId = $null
    for ($page = 0; $page -lt 20; $page++) {
        $uri = $endpoint
        if ($lastId) { $uri += '?after_id=' + [uri]::EscapeDataString($lastId) }
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 20 -ErrorAction Stop
        if ($response.success -eq $false -or -not $response.data) {
            throw '模型列表为空或返回格式不正确'
        }
        $models += @($response.data)
        if (-not $response.has_more) { return $models }
        $nextId = [string]$response.last_id
        if (-not $nextId -or $nextId -eq $lastId) { throw '模型列表分页信息不正确' }
        $lastId = $nextId
    }
    throw '模型列表分页数量超出限制'
}

function Select-LatestClaudeModel {
    param([object[]]$Models, [string]$Family)

    $candidates = foreach ($entry in $Models) {
        $id = [string]$entry.id
        $name = $id -replace '(?i)\[1m\]$', ''
        # 只选正式模型，跳过 -thinking 等变体；同时兼容旧版 claude-3-5-sonnet 命名。
        $pattern = '^claude-' + $Family + '-(?<major>\d+)(?:-(?<minor>\d{1,3}))?(?:-(?<date>\d{8}))?$'
        $legacyPattern = '^claude-(?<major>\d+)(?:-(?<minor>\d{1,3}))?-' + $Family + '(?:-(?<date>\d{8}))?$'
        if ($name -match $pattern -or $name -match $legacyPattern) {
            $major = [int]$Matches.major
            $minor = if ($Matches.minor) { [int]$Matches.minor } else { 0 }
            $date = if ($Matches.date) { [long]$Matches.date } else { 0 }
            $version = [version]("$major.$minor")
            # [1M] 只声明上下文能力，不能给不支持的模型扩容。
            $supports1M = ($Family -eq 'fable' -and $major -ge 5) -or
                ($Family -in @('opus', 'sonnet') -and $version -ge [version]'4.6')
            if ($entry.context_window -ge 1000000 -or $entry.max_input_tokens -ge 1000000) {
                $supports1M = $true
            }
            [PSCustomObject]@{
                Name = $name
                Major = $major
                Minor = $minor
                Date = $date
                Supports1M = $supports1M
            }
        }
    }
    $candidates | Sort-Object Major, Minor, Date -Descending | Select-Object -First 1
}

function Update-ClaudeModelMappings {
    param([object]$Settings, [object[]]$Models)

    foreach ($family in @('fable', 'opus', 'sonnet', 'haiku')) {
        $latest = Select-LatestClaudeModel -Models $Models -Family $family
        if (-not $latest) {
            Write-Host "[WARN] 未找到 $family 系列的正式模型，保留该系列原配置。" -ForegroundColor Yellow
            continue
        }
        $key = 'ANTHROPIC_DEFAULT_' + $family.ToUpperInvariant() + '_MODEL'
        $modelId = $latest.Name
        if ($latest.Supports1M) { $modelId += '[1M]' }
        $Settings.env | Add-Member -NotePropertyName $key -NotePropertyValue $modelId -Force
        $Settings.env | Add-Member -NotePropertyName ($key + '_NAME') -NotePropertyValue $latest.Name -Force
        Write-Host "[OK] $family 模型已更新：$modelId" -ForegroundColor Green
    }
}

try {
# 由实际使用 Claude 的用户运行；只有依赖安装包请求 UAC。
if (Test-IsAdministrator) {
    throw '请在普通权限窗口运行此脚本，以免将 npm 和 Claude 配置写入管理员账户。Git/Node 安装时会单独请求 UAC 授权。'
}
Refresh-Path
$architecture = $env:PROCESSOR_ARCHITEW6432
if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
switch ($architecture) {
    'ARM64' { $nodeArch = 'arm64'; $gitArch = 'arm64' }
    'AMD64' { $nodeArch = 'x64'; $gitArch = '64-bit' }
    default { throw "不支持的 Windows 架构：$architecture。此安装器支持 x64 和 ARM64。" }
}
$token = Read-Host "请粘贴你的 API Token (令牌密钥,从 $baseUrl 获取)"
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Token 不能为空'
}
Write-Host ""

# Git 和 Node.js 安装包共用本次运行独立的临时目录。
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempDir = Join-Path $tempRoot ("claude-install-" + [guid]::NewGuid().ToString("N"))
$tempDirCreated = $false

try {
    New-Item -ItemType Directory -Path $tempDir -ErrorAction Stop | Out-Null
    $tempDirCreated = $true

    # 1. 必须同时具备能运行的 Git 和 Git Bash。
    $git = Get-WorkingCommand -Names @('git.exe') -VersionPattern '^git version (.+)$'
    $gitBash = Find-GitBash -GitPath $git.Path
    if (-not $git -or -not $gitBash) {
        Write-Host "[..] Git 或 Git Bash 不可用，开始安装完整 Git for Windows..." -ForegroundColor Yellow
        $gitVersion = "2.47.1.2"
        $gitWinVersion = "v2.47.1.windows.2"
        $gitExe = "Git-$gitVersion-$gitArch.exe"
        $gitUrl = "https://registry.npmmirror.com/-/binary/git-for-windows/$gitWinVersion/$gitExe"
        $tempGit = Join-Path $tempDir $gitExe

        Write-Host "正在下载 Git $gitVersion ..." -ForegroundColor Yellow
        if (-not (Download-WithRetry -Url $gitUrl -Output $tempGit)) {
            throw 'Git 下载失败'
        }

        Write-Host "正在安装 Git ..." -ForegroundColor Yellow
        # 所有用户安装，防止 UAC 输入另一管理员账户后仅安装到其目录。
        Invoke-Installer -FilePath $tempGit -Arguments '/VERYSILENT /NORESTART /ALLUSERS' -Name 'Git'

        Refresh-Path

        $git = Get-WorkingCommand -Names @('git.exe') -VersionPattern '^git version (.+)$'
        $gitBash = Find-GitBash -GitPath $git.Path
        if (-not $git -or -not $gitBash) {
            throw 'Git 安装后验证失败：git.exe 或 Git Bash 无法运行。请检查 PATH；自定义安装可设置 CLAUDE_CODE_GIT_BASH_PATH。'
        }
    }
    Write-Host "[OK] Git $($git.Version)，Git Bash: $gitBash" -ForegroundColor Green
    $env:CLAUDE_CODE_GIT_BASH_PATH = $gitBash

    # 2. 当前 npm 包要求 Node >=22，且 npm.cmd 必须能正常运行。
    $nodeEnvironment = Get-NodeEnvironment
    if (-not $nodeEnvironment.Ready) {
        Write-Host "[..] Node.js 版本不足或 npm 不可用，开始安装/修复..." -ForegroundColor Yellow

        $repairArguments = ''
        if ($nodeEnvironment.Node -and [version]$nodeEnvironment.Node.Version -ge [version]'22.0.0') {
            # 已有更新版本但缺 npm 时修复同版本，避免静默降级。
            $nodeVersion = 'v' + $nodeEnvironment.Node.Version
            $repairArguments = ' REINSTALL=ALL REINSTALLMODE=vomus'
        } else {
            # 保留能用的 Node >=22；新装或低于 22 时使用最新 Node 24 正式版。
            $nodeVersion = Get-LatestNode24Version -Directory $tempDir -Architecture $nodeArch
        }
        $nodeMsi = "node-$nodeVersion-$nodeArch.msi"
        $tempMsi = Join-Path $tempDir $nodeMsi

        Write-Host "正在下载 Node.js $nodeVersion ..." -ForegroundColor Yellow
        if (-not (Download-NodePackage -Version $nodeVersion -Architecture $nodeArch -Output $tempMsi)) {
            throw 'Node.js 下载失败：国内镜像和官方源均未能提供可校验的安装包。请检查网络、代理或安全软件，稍后重试。'
        }

        Write-Host "正在安装 Node.js ..." -ForegroundColor Yellow
        Invoke-Installer -FilePath "$env:SystemRoot\System32\msiexec.exe" -Arguments "/i `"$tempMsi`" /qn /norestart ADDLOCAL=ALL$repairArguments" -Name 'Node.js' -SuccessCodes @(0, 3010)

        Refresh-Path

        $nodeEnvironment = Get-NodeEnvironment
        if (-not $nodeEnvironment.Ready) {
            throw 'Node.js/npm 安装后验证失败。请检查旧 Node 或版本管理器是否覆盖 PATH，切换至 Node >=22 且带 npm 的版本后重试。'
        }
    }
    Write-Host "[OK] Node.js $($nodeEnvironment.Node.Version)，npm $($nodeEnvironment.Npm.Version)" -ForegroundColor Green

} finally {
    # 正常完成、提前退出或出错时，只清理本次创建的目录。
    if ($tempDirCreated) {
        $resolvedTemp = [System.IO.Path]::GetFullPath($tempDir)
        if (-not $resolvedTemp.StartsWith($tempRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($resolvedTemp) -notlike 'claude-install-*') {
            throw '临时目录路径不正确，停止清理'
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 3. 使用 npm.cmd 避开 npm.ps1 执行策略，并验证真实命令退出码。
$npmPath = $nodeEnvironment.Npm.Path
$npmPrefix = Get-NpmPrefix -NpmPath $npmPath
$env:Path = "$npmPrefix;$env:Path"
$claude = Get-WorkingCommand -Names @('claude.cmd', 'claude.exe') -VersionPattern '^(\d+\.\d+\.\d+).*\(Claude Code\)'
if (-not $claude) {
    Write-Host "[..] Claude Code 缺失或无法运行，开始安装/修复..." -ForegroundColor Yellow
    # 镜像源仅对本次安装生效，不修改用户的 npm 配置。
    & $npmPath install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com
    if ($LASTEXITCODE -ne 0) { throw "Claude Code npm 安装失败，退出码 $LASTEXITCODE。请检查网络、npm prefix 和目录写入权限。" }
    $claude = Get-WorkingCommand -Names @('claude.cmd', 'claude.exe') -VersionPattern '^(\d+\.\d+\.\d+).*\(Claude Code\)'
    if (-not $claude) { throw 'Claude Code 安装后无法通过 --version 验证，请检查 npm 全局安装目录和 PATH。' }
}
# 同步用户 PATH，后续新开的终端也能找到自定义 prefix 中的命令。
Add-UserPath -Directory $npmPrefix
Write-Host "[OK] Claude Code $($claude.Version)" -ForegroundColor Green

# 5. 检查并清理可能冲突的环境变量，然后设置
Write-Host ""
Write-Host "正在检查环境变量..." -ForegroundColor Yellow

$conflictVars = @(
    "ANTHROPIC_API_KEY",
    "CLAUDE_API_KEY",
    "CLAUDE_CONFIG_DIR",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN"
)

$foundConflicts = @()
foreach ($var in $conflictVars) {
    $machineVal = [System.Environment]::GetEnvironmentVariable($var, "Machine")
    $userVal = [System.Environment]::GetEnvironmentVariable($var, "User")

    if ($machineVal) { $foundConflicts += "  [系统级] $var = $machineVal" }
    if ($userVal)    { $foundConflicts += "  [用户级] $var = $userVal" }
}

if ($foundConflicts.Count -gt 0) {
    Write-Host "[WARN] 检测到以下可能冲突的环境变量:" -ForegroundColor Yellow
    foreach ($c in $foundConflicts) {
        Write-Host $c -ForegroundColor Yellow
    }
    Write-Host ""

    $cleanVars = $conflictVars
    $hasStale = $false
    foreach ($var in $cleanVars) {
        $mv = [System.Environment]::GetEnvironmentVariable($var, "Machine")
        $uv = [System.Environment]::GetEnvironmentVariable($var, "User")
        if ($mv -or $uv) { $hasStale = $true; break }
    }

    if ($hasStale) {
        $choice = Read-Host "是否清理上述多余变量？(y/n，默认 y)"
        if ($choice -ne "n") {
            foreach ($var in $cleanVars) {
                $mv = [System.Environment]::GetEnvironmentVariable($var, "Machine")
                $uv = [System.Environment]::GetEnvironmentVariable($var, "User")
                if ($uv) {
                    [System.Environment]::SetEnvironmentVariable($var, $null, "User")
                    Remove-Item "Env:\$var" -ErrorAction SilentlyContinue
                    Write-Host "  已清理 [用户级] $var" -ForegroundColor Cyan
                }
                if ($mv) {
                    Write-Host "  [系统级] $var 需要管理员权限清理，请手动删除" -ForegroundColor Yellow
                }
            }
        }
    }
} else {
    Write-Host "[OK] 未发现冲突的环境变量。" -ForegroundColor Green
}

# 检查 settings.json 中与环境变量冲突的 key
$settingsPath = "$env:USERPROFILE\.claude\settings.json"
if (Test-Path $settingsPath) {
    try {
        $settingsJson = Get-Content -Path $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($settingsJson.env) {
            $envKeys = @($settingsJson.env.PSObject.Properties.Name)
            $conflicted = @()
            foreach ($key in $envKeys) {
                if ($conflictVars -contains $key) {
                    $conflicted += $key
                }
            }
            if ($conflicted.Count -gt 0) {
                Write-Host "[WARN] settings.json 中检测到以下冲突的 key:" -ForegroundColor Yellow
                foreach ($k in $conflicted) {
                    Write-Host "  - $k" -ForegroundColor Yellow
                }
            } else {
                Write-Host "[OK] settings.json 中无冲突的 key。" -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "[WARN] 读取 settings.json 失败: $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "[OK] 未找到 settings.json。" -ForegroundColor Green
}

# 写入 settings.json
Write-Host ""
Write-Host "正在写入配置到 settings.json..." -ForegroundColor Yellow
$settingsDir = "$env:USERPROFILE\.claude"
$settingsPath2 = "$settingsDir\settings.json"

# 确保目录存在
if (-not (Test-Path $settingsDir)) {
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
}

# 读取或创建 settings.json
if (Test-Path $settingsPath2) {
    try {
        $settings = Get-Content -Path $settingsPath2 -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "无法解析 $settingsPath2，已停止写入，请修复 JSON 后重试。"
    }
} else {
    $settings = [PSCustomObject]@{}
}

# 确保 env 字段存在
if (-not $settings.env) {
    $settings | Add-Member -NotePropertyName "env" -NotePropertyValue ([PSCustomObject]@{}) -Force
}

# 写入 ANTHROPIC_BASE_URL 和 ANTHROPIC_AUTH_TOKEN
$settings.env | Add-Member -NotePropertyName "ANTHROPIC_BASE_URL" -NotePropertyValue $baseUrl -Force
$settings.env | Add-Member -NotePropertyName "ANTHROPIC_AUTH_TOKEN" -NotePropertyValue $token -Force
$settings.env | Add-Member -NotePropertyName "CLAUDE_CODE_GIT_BASH_PATH" -NotePropertyValue $gitBash -Force

# 每次配置都获取当前 Token 可用的模型，不把某个版本永久写死在安装脚本里。
Write-Host "正在获取最新可用的 Claude 模型..." -ForegroundColor Yellow
try {
    $availableModels = @(Get-ClaudeModels -BaseUrl $baseUrl -Token $token)
    Update-ClaudeModelMappings -Settings $settings -Models $availableModels
} catch {
    # 不回显 HTTP 异常或响应正文，避免中转服务错误信息泄漏 Token。
    Write-Host "[WARN] 获取模型列表失败，保留原有模型配置；API 地址和 Token 仍会更新。" -ForegroundColor Yellow
}

# 设置当前进程环境变量（供后续 claude 启动使用）
$env:ANTHROPIC_BASE_URL = $baseUrl
$env:ANTHROPIC_AUTH_TOKEN = $token

$settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath2 -Encoding UTF8
Write-Host "[OK] 配置已写入 $settingsPath2" -ForegroundColor Green

# 6. 启动 claude
Write-Host ""
Write-Host "========================================"
Write-Host "  安装完成！"
Write-Host "========================================"
Write-Host ""
Write-Host "提示：脚本即将启动 Claude Code。" -ForegroundColor Cyan
Write-Host "如需稍后手动启动，请在命令行输入: claude" -ForegroundColor Cyan
Write-Host ""
Read-Host "按回车键启动 Claude Code"

Write-Host "正在启动 claude..." -ForegroundColor Yellow
& $claude.Path
if ($LASTEXITCODE -ne 0) { throw "Claude Code 退出码：$LASTEXITCODE" }
} catch {
    Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
