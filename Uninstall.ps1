[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$TaskName = 'iFudan.stu Auto Login'
$InstallDir = Join-Path $env:LOCALAPPDATA 'iFudanAutoLogin'

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host ('已删除计划任务：{0}' -f $TaskName)
}
if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host ('已删除本地凭据和脚本：{0}' -f $InstallDir)
}
Write-Host '卸载完成。' -ForegroundColor Green

