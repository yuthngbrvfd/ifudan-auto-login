[CmdletBinding()]
param(
    [string]$ExpectedSid = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 does not always preload this DPAPI assembly.
Add-Type -AssemblyName System.Security -ErrorAction Stop

$TaskName = 'iFudan.stu Auto Login'
$Ssid = 'iFudan.stu'
$PortalBase = 'http://10.102.250.36'
$InstallDir = Join-Path $env:LOCALAPPDATA 'iFudanAutoLogin'
$SourceDir = $PSScriptRoot
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Creating an event-triggered task requires elevation on this computer.
# Elevate before asking for any credential. The parent console waits for completion.
$currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (-not (Test-IsAdministrator)) {
    Write-Host '需要管理员权限来创建 Wi-Fi 连接事件触发的计划任务。即将显示 Windows UAC 提示。' -ForegroundColor Yellow
    $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -ExpectedSid "' + $currentSid + '"'
    try {
        $elevated = Start-Process -FilePath $PowerShellExe -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru
        exit $elevated.ExitCode
    } catch {
        throw '未获得管理员权限，安装已停止。请重新运行 Install.cmd 并允许 UAC 提示。'
    }
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedSid) -and $currentSid -ne $ExpectedSid) {
    throw 'UAC 使用了另一个 Windows 账户。为保证 DPAPI 凭据属于正确用户，请使用当前登录账户批准 UAC。'
}

function Invoke-JsonPost {
    param([string]$Uri, [hashtable]$Body)
    $json = $Body | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
        return Invoke-RestMethod -Uri $Uri -Method Post -ContentType 'application/json;charset=gbk' -Body $bytes -TimeoutSec 12
    } finally {
        if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Get-CurrentOutport {
    try {
        $ipResult = Invoke-RestMethod -Uri ($PortalBase + '/api/v1/ip') -TimeoutSec 10
        if ($ipResult.code -ne 200) { return '' }
        $state = Invoke-JsonPost -Uri ($PortalBase + '/api/v1/pre_login') -Body @{
            getuseronlinestate = 'on_or_off'
            user_ipadress      = [string]$ipResult.data
        }
        if ($state.code -eq 200 -and [string]$state.data.useronlinestate -eq 'on') {
            return [string]$state.data.outport
        }
    } catch {}
    return ''
}

function Protect-DirectoryForCurrentUser {
    param([string]$Path)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $identity,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([System.Security.Principal.WindowsIdentity]::GetCurrent().User)
    $security.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Test-StoredCredential {
    param([string]$Path)
    $protected = $null
    $plainBytes = $null
    $json = $null
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $protected = [System.IO.File]::ReadAllBytes($Path)
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $json = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        $stored = $json | ConvertFrom-Json
        return (-not [string]::IsNullOrWhiteSpace([string]$stored.Username) -and
                -not [string]::IsNullOrEmpty([string]$stored.Password))
    } catch {
        return $false
    } finally {
        if ($protected) { [Array]::Clear($protected, 0, $protected.Length) }
        if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        $json = $null
    }
}

Write-Host ''
Write-Host 'iFudan.stu 自动登录安装程序' -ForegroundColor Cyan
Write-Host '凭据将由 Windows DPAPI 加密，只能由当前 Windows 用户在本机解密。'
Write-Host '用户名和密码不会写入日志，也不会发送到校园网登录接口以外的位置。'
Write-Host ''

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$secretPath = Join-Path $InstallDir 'secret.bin'
$configPath = Join-Path $InstallDir 'config.json'
$reuseStoredCredential = (Test-Path -LiteralPath $configPath) -and (Test-StoredCredential -Path $secretPath)

if ($reuseStoredCredential) {
    Write-Host '检测到上次已成功加密保存的凭据，本次将直接复用，无需再次输入。' -ForegroundColor Green
} else {
    $username = (Read-Host '请输入校园网用户名/学号').Trim()
    if ([string]::IsNullOrWhiteSpace($username)) { throw '用户名不能为空。' }
    $securePassword = Read-Host '请输入校园网密码（输入时不显示）' -AsSecureString
    if (-not $securePassword -or $securePassword.Length -eq 0) { throw '密码不能为空。' }

    $detectedOutport = Get-CurrentOutport
    if (-not [string]::IsNullOrWhiteSpace($detectedOutport)) {
        $preferredChannelName = Read-Host ('检测到当前出口为“{0}”。按回车使用它，或输入其他出口名称' -f $detectedOutport)
        if ([string]::IsNullOrWhiteSpace($preferredChannelName)) { $preferredChannelName = $detectedOutport }
    } else {
        $preferredChannelName = Read-Host '如账号有多个出口，请输入偏好出口名称；不确定可直接回车'
    }

    $bstr = [IntPtr]::Zero
    $plainPassword = $null
    $plainBytes = $null
    $protectedBytes = $null
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $secretJson = @{ Username = $username; Password = $plainPassword } | ConvertTo-Json -Compress
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($secretJson)
        $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [System.IO.File]::WriteAllBytes($secretPath, $protectedBytes)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($protectedBytes) { [Array]::Clear($protectedBytes, 0, $protectedBytes.Length) }
        $plainPassword = $null
        $securePassword = $null
    }

    $config = [ordered]@{
        Ssid                 = $Ssid
        PortalBase           = $PortalBase
        PreferredChannelId   = ''
        PreferredChannelName = [string]$preferredChannelName
    }
    $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
}

Copy-Item -LiteralPath (Join-Path $SourceDir 'AutoLogin.ps1') -Destination (Join-Path $InstallDir 'AutoLogin.ps1') -Force
Protect-DirectoryForCurrentUser -Path $InstallDir

$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$scriptPath = Join-Path $InstallDir 'AutoLogin.ps1'
$subscription = "<QueryList><Query Id='0' Path='Microsoft-Windows-WLAN-AutoConfig/Operational'><Select Path='Microsoft-Windows-WLAN-AutoConfig/Operational'>*[System[(EventID=8001)]] and *[EventData[Data[@Name='SSID']='$Ssid']]</Select></Query></QueryList>"
$subEscaped = [System.Security.SecurityElement]::Escape($subscription)
$commandEscaped = [System.Security.SecurityElement]::Escape($PowerShellExe)
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
$argumentsEscaped = [System.Security.SecurityElement]::Escape($arguments)

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Automatically authenticates this Windows user on iFudan.stu after Wi-Fi connection.</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$subEscaped</Subscription>
      <Delay>PT5S</Delay>
    </EventTrigger>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Delay>PT15S</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT3M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$commandEscaped</Command>
      <Arguments>$argumentsEscaped</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $TaskName -Xml $taskXml -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

$task = $null
$info = $null
foreach ($attempt in 1..15) {
    Start-Sleep -Seconds 1
    $task = Get-ScheduledTask -TaskName $TaskName
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    if ([string]$task.State -ne 'Running') { break }
}

Write-Host ''
Write-Host '安装完成。' -ForegroundColor Green
Write-Host ('计划任务：{0}（状态：{1}）' -f $TaskName, $task.State)
Write-Host ('安装目录：{0}' -f $InstallDir)
Write-Host ('最近运行结果：0x{0:X8}' -f ([uint32]$info.LastTaskResult))
Write-Host '以后连接 iFudan.stu 后会自动检查并认证；已联网时不会重复登录。'
Write-Host '如需测试，请断开并重新连接该 Wi-Fi。'

