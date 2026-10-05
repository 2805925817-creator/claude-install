# claude-install
一键安装配置claude code所需环境

请以普通权限双击 `一键安装.bat`，或在普通 PowerShell 窗口执行远程命令。
只有 Git / Node.js 安装程序请求 UAC 提权；npm 安装、用户 PATH 和 Claude 配置始终由原用户完成。
在管理员窗口运行脚本会直接停止，避免把配置写入其他账户。

支持 x64 / ARM64 Windows。检测 Git 与 Git Bash 均可运行，并将 Bash 的路径写入 Claude 配置。
已有 Node.js >=22 且 npm 可运行时保留，不强制升级到 24；没有可运行的 Node 或版本低于 22 时，安装 Node 24 系列最新正式版。已有 Node >=22 但 npm 不可用时尝试修复同版本。
Node 24 版本号从官方 `latest-v24.x` 校验清单动态获取；官方不可达时依次查询华为云和 npmmirror（镜像清单可能有同步延迟）。只选择 24 系列正式版本，不跨到其他大版本或预发行版。
使用版本管理器或便携版 Node 的用户，如修复后验证仍失败，请切换至包含 npm 的 Node >=22 后重试。
下载检查 HTTP 错误，并限制连接和总下载时间；Git、Node、npm 安装失败会停止并报告退出码。
Node.js 按顺序尝试 npmmirror、华为云镜像、Node 官方源，失败或校验不匹配立即换源。每个源连接超时 10 秒，安装包下载最多 180 秒，连续 30 秒低于 1 KB/s 时中止并换源；安装包必须通过对应版本的 SHA-256 校验后才能安装。
Claude Code 必须通过 `--version` 验证才判定成功，自定义 npm 全局目录会加入用户 PATH。
系统安装程序、版本管理器和不同账户的 UAC 行为仍建议在干净 Windows 虚拟机中验证。

Git 和 Node.js 安装包统一下载到系统临时目录下的 `claude-install-<随机 ID>` 子目录。
每次运行使用独立目录，兼容本地脚本和远程执行；依赖安装完成、提前退出或发生错误时自动清理。

Claude Code 安装通过命令行参数临时使用 npm 国内镜像源，安装成功或失败都保留用户原有的 npm 源配置。

配置时覆盖 `~/.claude/settings.json` 中的 API 地址和 Token，并使用本次输入的 Token 从 `https://tdyun.ai/v1/models` 获取可用模型。
按版本号为 Fable、Opus、Sonnet、Haiku 各选一个最新正式版本（跳过 `-thinking` 等变体），覆盖对应的 `ANTHROPIC_DEFAULT_*_MODEL` 和 `ANTHROPIC_DEFAULT_*_MODEL_NAME`。
支持 1M 的 Fable、Opus、Sonnet 版本追加 `[1M]`，显示名称不带后缀；当前 Haiku 只支持 200K，不追加 `[1M]`。中转服务实际上下文上限由服务端决定。
模型列表获取失败或某个系列不可用时，保留对应原配置；顶层 `model`、`env.ANTHROPIC_MODEL` 和其他设置不变。因此，旧配置若指定了完整模型 ID，仍使用该 ID；若指定的是 `opus` 等系列别名，则使用更新后的映射。
已有 `settings.json` 无法解析时停止写入，避免覆盖原文件。

模型配置逻辑可通过 `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ModelConfiguration.ps1` 验证，无需运行安装程序或修改本机 Claude 配置。

安装失败场景可通过 `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-Installation.ps1` 模拟验证，不运行真实安装或修改用户配置。

可选联网检查：`powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-NodeDownloads.ps1` 会完整下载三个源的 x64/ARM64 安装包，检查 SHA-256 和跨源一致性；只使用临时目录，不安装 Node，也不修改用户配置。
