# claude-install
一键安装配置claude code所需环境

Git 和 Node.js 安装包统一下载到系统临时目录下的 `claude-install-<随机 ID>` 子目录。
每次运行使用独立目录，兼容本地脚本和远程执行；依赖安装完成、提前退出或发生错误时自动清理。
