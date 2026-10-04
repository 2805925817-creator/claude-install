# claude-install
一键安装配置claude code所需环境

Git 和 Node.js 安装包统一下载到系统临时目录下的 `claude-install-<随机 ID>` 子目录。
每次运行使用独立目录，兼容本地脚本和远程执行；依赖安装完成、提前退出或发生错误时自动清理。

Claude Code 安装通过命令行参数临时使用 npm 国内镜像源，安装成功或失败都保留用户原有的 npm 源配置。

配置时覆盖 `~/.claude/settings.json` 中的 API 地址和 Token，并使用本次输入的 Token 从 `https://tdyun.ai/v1/models` 获取可用模型。
按版本号为 Fable、Opus、Sonnet、Haiku 各选一个最新正式版本（跳过 `-thinking` 等变体），覆盖对应的 `ANTHROPIC_DEFAULT_*_MODEL` 和 `ANTHROPIC_DEFAULT_*_MODEL_NAME`。
支持 1M 的 Fable、Opus、Sonnet 版本追加 `[1M]`，显示名称不带后缀；当前 Haiku 只支持 200K，不追加 `[1M]`。中转服务实际上下文上限由服务端决定。
模型列表获取失败或某个系列不可用时，保留对应原配置；顶层 `model`、`env.ANTHROPIC_MODEL` 和其他设置不变。因此，旧配置若指定了完整模型 ID，仍使用该 ID；若指定的是 `opus` 等系列别名，则使用更新后的映射。
已有 `settings.json` 无法解析时停止写入，避免覆盖原文件。

模型配置逻辑可通过 `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ModelConfiguration.ps1` 验证，无需运行安装程序或修改本机 Claude 配置。
