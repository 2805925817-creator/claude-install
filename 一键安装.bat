@echo off
chcp 65001 >nul 2>&1
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)
set ERRFILE=%TEMP%\claude_install_err.txt
powershell -ExecutionPolicy Bypass -File "%~dp0install.ps1" 2>"%ERRFILE%"
if %errorlevel% neq 0 (
    echo.
    echo [错误] 安装脚本执行失败，错误信息如下：
    type "%ERRFILE%"
    pause
)
del "%ERRFILE%" >nul 2>&1