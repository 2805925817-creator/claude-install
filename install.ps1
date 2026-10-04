$baseUrl = "https://tdyun.ai"
$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "========================================"
Write-Host "  Claude Code 一键安装脚本"
Write-Host "========================================"
Write-Host ""

function Refresh-Path {
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Download-WithRetry {
    param(
        [string]$Url,
        [string]$Output,
        [int]$MaxRetries = 3
    )

    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Host "下载中 (尝试 $i/$MaxRetries)..." -ForegroundColor Yellow
        curl.exe -L --progress-bar -o $Output $Url
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
        if ($i -lt $MaxRetries) {
            Write-Host "下载失败，3秒后重试..." -ForegroundColor Yellow
            Start-Sleep -Seconds 3
        }
    }
    return $false
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

$token = Read-Host "请粘贴你的 API Token (令牌密钥,从 $baseUrl 获取)"
if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "[FAIL] Token 不能为空" -ForegroundColor Red
    Read-Host "按回车键退出"
    exit
}
Write-Host ""

# Git 和 Node.js 安装包共用本次运行独立的临时目录。
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempDir = Join-Path $tempRoot ("claude-install-" + [guid]::NewGuid().ToString("N"))
$tempDirCreated = $false

try {
    New-Item -ItemType Directory -Path $tempDir -ErrorAction Stop | Out-Null
    $tempDirCreated = $true

    # 1. 检查 Git (claude code 依赖 git-bash)
    $gitInstalled = Get-Command git -ErrorAction SilentlyContinue
    if ($gitInstalled) {
        Write-Host "[OK] Git 已安装: $(git --version)" -ForegroundColor Green
    } else {
        Write-Host "[..] 未检测到 Git，开始安装..." -ForegroundColor Yellow

        $gitVersion = "2.47.1.2"
        $gitWinVersion = "v2.47.1.windows.2"
        if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
            $gitExe = "Git-$gitVersion-arm64.exe"
        } else {
            $gitExe = "Git-$gitVersion-64-bit.exe"
        }
        $gitUrl = "https://registry.npmmirror.com/-/binary/git-for-windows/$gitWinVersion/$gitExe"
        $tempGit = Join-Path $tempDir $gitExe

        Write-Host "正在下载 Git $gitVersion ..." -ForegroundColor Yellow
        if (-not (Download-WithRetry -Url $gitUrl -Output $tempGit)) {
            Write-Host "[FAIL] Git 下载失败" -ForegroundColor Red
            Read-Host "按回车键退出"
            exit
        }

        Write-Host "正在安装 Git ..." -ForegroundColor Yellow
        Start-Process -FilePath $tempGit -ArgumentList "/VERYSILENT /NORESTART" -Wait -NoNewWindow

        Refresh-Path

        $gitCheck = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCheck) {
            Write-Host "[OK] Git 安装成功: $(git --version)" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] Git 安装失败" -ForegroundColor Red
            Read-Host "按回车键退出"
            exit
        }
    }

    # 2. 检查 Node.js
    $nodeInstalled = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeInstalled) {
        Write-Host "[OK] Node.js 已安装: $(node --version)" -ForegroundColor Green
    } else {
        Write-Host "[..] 未检测到 Node.js，开始安装..." -ForegroundColor Yellow

        $nodeVersion = "v22.15.0"
        if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
            $nodeArch = "arm64"
        } else {
            $nodeArch = "x64"
        }
        $nodeMsi = "node-$nodeVersion-$nodeArch.msi"
        $nodeUrl = "https://cdn.npmmirror.com/binaries/node/$nodeVersion/$nodeMsi"
        $tempMsi = Join-Path $tempDir $nodeMsi

        Write-Host "正在下载 Node.js $nodeVersion ..." -ForegroundColor Yellow
        if (-not (Download-WithRetry -Url $nodeUrl -Output $tempMsi)) {
            Write-Host "[FAIL] Node.js 下载失败" -ForegroundColor Red
            Read-Host "按回车键退出"
            exit
        }

        Write-Host "正在安装 Node.js ..." -ForegroundColor Yellow
        Start-Process msiexec.exe -ArgumentList "/i `"$tempMsi`" /qn /norestart" -Wait -NoNewWindow

        Refresh-Path

        $nodeCheck = Get-Command node -ErrorAction SilentlyContinue
        if ($nodeCheck) {
            Write-Host "[OK] Node.js 安装成功: $(node --version)" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] Node.js 安装失败" -ForegroundColor Red
            Read-Host "按回车键退出"
            exit
        }
    }

} finally {
    # 正常完成、提前退出或出错时，只清理本次创建的目录。
    if ($tempDirCreated) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 3. 检查 Claude Code
$installed = Get-Command claude -ErrorAction SilentlyContinue
if ($installed) {
    Write-Host "[OK] Claude Code 已安装，无需重复安装。" -ForegroundColor Green
    claude --version
} else {
    Write-Host "[..] 未检测到 Claude Code，开始安装..." -ForegroundColor Yellow
    Write-Host ""

    # 镜像源仅对本次安装生效，不修改用户的 npm 配置。
    Write-Host "本次安装使用 npm 国内镜像源..." -ForegroundColor Yellow
    npm install -g @anthropic-ai/claude-code --registry=https://registry.npmmirror.com

    Write-Host ""
    Write-Host "正在验证安装结果..."

    $npmPrefix = (npm prefix -g).Trim()
    $env:Path = "$npmPrefix;$env:Path"

    $installed = Get-Command claude -ErrorAction SilentlyContinue
    if ($installed) {
        Write-Host "[OK] 安装成功！" -ForegroundColor Green
        claude --version
    } else {
        Write-Host "[FAIL] 安装似乎未成功" -ForegroundColor Red
        Read-Host "按回车键退出"
        exit
    }
}

# 4. 关闭 claude 进程
Write-Host ""
Write-Host "正在关闭 claude 进程..." -ForegroundColor Yellow
Stop-Process -Name claude -Force -ErrorAction SilentlyContinue

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
& cmd.exe /c claude
