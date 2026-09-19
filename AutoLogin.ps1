[CmdletBinding()]
param(
    [switch]$StatusOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 does not always preload the .NET Framework assembly
# that contains ProtectedData. Loading it explicitly keeps DPAPI available.
Add-Type -AssemblyName System.Security -ErrorAction Stop

$InstallDir = $PSScriptRoot
$ConfigPath = Join-Path $InstallDir 'config.json'
$SecretPath = Join-Path $InstallDir 'secret.bin'
$LogPath = Join-Path $InstallDir 'AutoLogin.log'

function Write-Log {
    param([string]$Message)
    try {
        if (Test-Path -LiteralPath $LogPath) {
            $item = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
            if ($item -and $item.Length -gt 262144) {
                Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.old') -Force
            }
        }
        Add-Content -LiteralPath $LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) -Encoding UTF8
    } catch {
        # Logging failure must not make network authentication fail.
    }
}

function Get-CurrentSsid {
    try {
        $text = (& netsh wlan show interfaces 2>$null) -join "`n"
        $match = [regex]::Match($text, '(?m)^\s*SSID\s*:\s*(.+?)\s*$')
        if ($match.Success) { return $match.Groups[1].Value.Trim() }
    } catch {}
    return $null
}

function Invoke-JsonPost {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][hashtable]$Body
    )
    $json = $Body | ConvertTo-Json -Compress -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
        return Invoke-RestMethod -Uri $Uri -Method Post -ContentType 'application/json;charset=gbk' -Body $bytes -TimeoutSec 12
    } finally {
        if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Test-PublicInternet {
    try {
        $response = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 6
        return (($response.Content).Trim() -eq 'Microsoft Connect Test')
    } catch {
        return $false
    }
}

function Get-PortalState {
    param([string]$PortalBase)
    $ipResponse = Invoke-RestMethod -Uri ($PortalBase.TrimEnd('/') + '/api/v1/ip') -Method Get -TimeoutSec 10
    if ($ipResponse.code -ne 200 -or [string]::IsNullOrWhiteSpace([string]$ipResponse.data)) {
        throw 'Portal IP lookup failed.'
    }
    $ip = [string]$ipResponse.data
    $state = Invoke-JsonPost -Uri ($PortalBase.TrimEnd('/') + '/api/v1/pre_login') -Body @{
        getuseronlinestate = 'on_or_off'
        user_ipadress      = $ip
    }
    return [pscustomobject]@{ Ip = $ip; Response = $state }
}

function Read-ProtectedCredential {
    if (-not (Test-Path -LiteralPath $SecretPath)) { throw 'Credential file is missing. Run Install.ps1 again.' }
    $protected = [System.IO.File]::ReadAllBytes($SecretPath)
    $plainBytes = $null
    $json = $null
    try {
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $json = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        $credential = $json | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$credential.Username) -or [string]::IsNullOrEmpty([string]$credential.Password)) {
            throw 'Stored credential is incomplete.'
        }
        return $credential
    } finally {
        if ($protected) { [Array]::Clear($protected, 0, $protected.Length) }
        if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        $json = $null
    }
}

function Get-SafeErrorText {
    param($Response)
    try {
        if ($Response.data -and $Response.data.text) { return [string]$Response.data.text }
    } catch {}
    return 'Portal rejected the request.'
}

$mutex = $null
$lockTaken = $false
$credential = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\iFudanAutoLogin')
    $lockTaken = $mutex.WaitOne(0, $false)
    if (-not $lockTaken) { exit 0 }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if ($StatusOnly) {
            Write-Output 'Installed=False'
            exit 0
        }
        throw 'Configuration is missing. Run Install.ps1.'
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ssid = Get-CurrentSsid
    if ($StatusOnly) { Write-Output ('SSID={0}' -f $(if ($ssid) { $ssid } else { '<none>' })) }
    if ($ssid -ne [string]$config.Ssid) {
        if ($StatusOnly) { Write-Output 'TargetNetwork=False' }
        exit 0
    }

    $portalState = $null
    $lastError = $null
    foreach ($attempt in 1..3) {
        try {
            $portalState = Get-PortalState -PortalBase ([string]$config.PortalBase)
            break
        } catch {
            $lastError = $_
            if ($attempt -lt 3) { Start-Sleep -Seconds (2 * $attempt) }
        }
    }
    if (-not $portalState) { throw $lastError }

    $onlineState = [string]$portalState.Response.data.useronlinestate
    if ($StatusOnly) {
        Write-Output ('PortalOnline={0}' -f ($onlineState -eq 'on'))
        Write-Output ('PublicInternet={0}' -f (Test-PublicInternet))
        exit 0
    }
    if ($onlineState -eq 'on') {
        Write-Log 'Already authenticated; no action needed.'
        exit 0
    }

    $credential = Read-ProtectedCredential
    $common = @{
        username    = [string]$credential.Username
        password    = [string]$credential.Password
        ifautologin = '1'
        channel     = '_GET'
        pagesign    = 'firstauth'
        usripadd    = [string]$portalState.Ip
    }
    $login = Invoke-JsonPost -Uri (([string]$config.PortalBase).TrimEnd('/') + '/api/v1/login') -Body $common

    if ($login.code -ne 200) {
        throw (Get-SafeErrorText -Response $login)
    }

    $channels = @()
    if ($login.data -and $login.data.channels) { $channels = @($login.data.channels) }
    if ($channels.Count -gt 0) {
        $selected = $null
        $preferredId = [string]$config.PreferredChannelId
        $preferredName = [string]$config.PreferredChannelName

        if (-not [string]::IsNullOrWhiteSpace($preferredId)) {
            $selected = $channels | Where-Object { [string]$_.id -eq $preferredId } | Select-Object -First 1
        }
        if (-not $selected -and -not [string]::IsNullOrWhiteSpace($preferredName)) {
            $selected = $channels | Where-Object {
                ([string]$_.name -eq $preferredName) -or ([string]$_.name -like ('*' + $preferredName + '*'))
            } | Select-Object -First 1
        }
        if (-not $selected -and $channels.Count -eq 1) { $selected = $channels[0] }
        if (-not $selected) {
            $names = ($channels | ForEach-Object { [string]$_.name }) -join ', '
            throw ('Multiple network exits are available but none matches the configured preference. Available: ' + $names)
        }

        $channelId = [string]$selected.id
        $second = @{
            username    = [string]$credential.Username
            password    = [string]$credential.Password
            ifautologin = '1'
            channel     = $channelId
            pagesign    = $(if ($channelId -eq '0') { 'thirdauth' } else { 'secondauth' })
            usripadd    = [string]$portalState.Ip
        }
        $login = Invoke-JsonPost -Uri (([string]$config.PortalBase).TrimEnd('/') + '/api/v1/login') -Body $second
        if ($login.code -ne 200) { throw (Get-SafeErrorText -Response $login) }
    }

    $verified = $false
    foreach ($attempt in 1..3) {
        Start-Sleep -Seconds 2
        try {
            $check = Get-PortalState -PortalBase ([string]$config.PortalBase)
            if ([string]$check.Response.data.useronlinestate -eq 'on') {
                $verified = $true
                break
            }
        } catch {}
    }
    if (-not $verified) { throw 'Login request returned successfully, but the online state could not be verified.' }

    Write-Log ('Authentication succeeded. Public Internet check: {0}.' -f (Test-PublicInternet))
    exit 0
} catch {
    Write-Log ('ERROR: ' + $_.Exception.Message)
    if ($StatusOnly) { Write-Output ('Error={0}' -f $_.Exception.Message) }
    exit 1
} finally {
    $credential = $null
    if ($lockTaken -and $mutex) { try { $mutex.ReleaseMutex() } catch {} }
    if ($mutex) { $mutex.Dispose() }
    [GC]::Collect()
}
