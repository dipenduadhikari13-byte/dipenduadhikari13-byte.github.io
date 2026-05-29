#Requires -Version 5.1

<#
    Internal Keyboard Disabler

    Designed for:
      irm https://dipendu.me/disable-keyboard.ps1 | iex
#>

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Host ""
    Write-Host "[ERROR] This script must run under Windows PowerShell 5.1" -ForegroundColor Red
    Write-Host "Use Windows PowerShell (powershell.exe), not pwsh." -ForegroundColor Yellow
    Write-Host ""
    pause
    exit
}

if ([string]::IsNullOrWhiteSpace($MyInvocation.ScriptName)) {
    Write-Host ""
    Write-Host "[BOOTSTRAP] Running from memory..." -ForegroundColor Cyan

    try {
        $scriptUrl = 'https://dipendu.me/disable-keyboard.ps1'
        $scriptPath = Join-Path $env:TEMP 'disable-keyboard.ps1'
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        $minimumDownloadBytes = 3000

        Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath -UseBasicParsing -ErrorAction Stop

        if (-not (Test-Path $scriptPath)) {
            throw "Downloaded file missing."
        }

        if ((Get-Item $scriptPath).Length -lt $minimumDownloadBytes) {
            throw "Downloaded file looks incomplete."
        }

        if (Test-IsAdmin) {
            Start-Process powershell.exe -ArgumentList $arguments -Wait
        }
        else {
            Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -Wait
        }
    }
    catch {
        Write-Host ""
        Write-Host "[BOOTSTRAP ERROR] $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Manual fallback:" -ForegroundColor Yellow
        Write-Host "  irm https://dipendu.me/disable-keyboard.ps1 -OutFile disable-keyboard.ps1"
        Write-Host "  powershell -ExecutionPolicy Bypass -File .\disable-keyboard.ps1"
        Write-Host ""
        pause
    }

    return
}

if (-not (Test-IsAdmin)) {
    Write-Host "[ELEVATION] Requesting administrator access..." -ForegroundColor Yellow

    Start-Process powershell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.ScriptName)`"" `
        -Verb RunAs `
        -Wait

    exit
}

Set-ExecutionPolicy Bypass -Scope Process -Force

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
}
catch {
    Write-Host ""
    Write-Host "[GUI ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    pause
    exit
}

$stateRoot = Join-Path $env:ProgramData 'InternalKeyboardDisabler'
$statePath = Join-Path $stateRoot 'disabled-keyboards.json'
$restoreScriptPath = Join-Path $stateRoot 'enable-disabled-keyboards.ps1'
$userDesktopRestorePath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Enable Disabled Keyboards.cmd'
$publicDesktopRestorePath = Join-Path $env:PUBLIC 'Desktop\Enable Disabled Keyboards.cmd'

function Ensure-StateDirectory {
    if (-not (Test-Path $stateRoot)) {
        New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null
    }
}

function Read-DisabledState {
    if (-not (Test-Path $statePath)) {
        return @()
    }

    try {
        $data = Get-Content $statePath -Raw | ConvertFrom-Json
        if ($null -eq $data) {
            return @()
        }
        return @($data)
    }
    catch {
        return @()
    }
}

function Write-DisabledState([array]$instanceIds) {
    Ensure-StateDirectory
    @($instanceIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) |
        ConvertTo-Json |
        Set-Content -Path $statePath -Encoding UTF8
}

function Get-DevicePropertyValue {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [Parameter(Mandatory = $true)][string]$KeyName
    )

    try {
        $value = (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop).Data
        if ($null -eq $value) { return '' }
        return [string]$value
    }
    catch {
        return ''
    }
}

function Test-IsLikelyInternalKeyboard {
    param([Parameter(Mandatory = $true)]$Device)

    $instanceId = [string]$Device.InstanceId
    $enumerator = Get-DevicePropertyValue -InstanceId $instanceId -KeyName 'DEVPKEY_Device_EnumeratorName'
    $location = Get-DevicePropertyValue -InstanceId $instanceId -KeyName 'DEVPKEY_Device_LocationInfo'

    $looksExternal = (
        $instanceId -like 'USB\*' -or
        $instanceId -like 'BTH\*' -or
        $enumerator -match 'USB|BTH' -or
        $location -match 'USB'
    )

    if ($looksExternal) {
        return $false
    }

    if (
        $instanceId -like 'ACPI\*' -or
        $instanceId -like '*PNP030*' -or
        $enumerator -match 'ACPI|PCI|I2C|ISAPNP|ROOT'
    ) {
        return $true
    }

    return $false
}

function Disable-KeyboardById([string]$instanceId) {
    try {
        Disable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction Stop | Out-Null
        return
    }
    catch {
        & pnputil.exe /disable-device "$instanceId" /force | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "pnputil.exe disable failed with exit code $LASTEXITCODE for device '$instanceId'."
        }
    }
}

function Enable-KeyboardById([string]$instanceId) {
    try {
        Enable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction Stop | Out-Null
        return
    }
    catch {
        & pnputil.exe /enable-device "$instanceId" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "pnputil.exe enable failed with exit code $LASTEXITCODE for device '$instanceId'."
        }
    }
}

function Ensure-RestoreAssets {
    Ensure-StateDirectory
    $statePathEscaped = $statePath.Replace("'", "''")

    $restoreScript = @"
#Requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
`$statePath = '$statePathEscaped'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"`$PSCommandPath`"" -Verb RunAs
    exit
}
if (-not (Test-Path `$statePath)) {
    [System.Windows.Forms.MessageBox]::Show("No saved disabled keyboards were found.", "Restore Keyboards")
    exit
}
`$ids = @((Get-Content `$statePath -Raw | ConvertFrom-Json))
`$failedIds = @()
foreach (`$id in `$ids) {
    try {
        Enable-PnpDevice -InstanceId `$id -Confirm:`$false -ErrorAction Stop | Out-Null
    }
    catch {
        & pnputil.exe /enable-device "`$id" | Out-Null
        if (`$LASTEXITCODE -ne 0) {
            `$failedIds += "`$id"
        }
    }
}
if (`$failedIds.Count -gt 0) {
    [System.Windows.Forms.MessageBox]::Show(
        "Failed to restore the following keyboard device(s):`r`n`r`n" + (`$failedIds -join "`r`n"),
        "Restore Keyboards"
    )
    exit 1
}
[System.Windows.Forms.MessageBox]::Show("Restore command completed. Reboot if a keyboard is still disabled.", "Restore Keyboards")
"@
    $restoreScript | Set-Content -Path $restoreScriptPath -Encoding UTF8

    $cmdContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$restoreScriptPath"
"@
    $cmdContent | Set-Content -Path $userDesktopRestorePath -Encoding ASCII
    if (Test-Path (Split-Path $publicDesktopRestorePath -Parent)) {
        $cmdContent | Set-Content -Path $publicDesktopRestorePath -Encoding ASCII
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Internal Keyboard Disabler'
$form.Size = New-Object System.Drawing.Size(760, 560)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 30)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Internal Keyboard Disabler'
$title.ForeColor = 'White'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20, 20)
$form.Controls.Add($title)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Only likely INTERNAL keyboards can be disabled. External USB/Bluetooth keyboards are protected.'
$hint.ForeColor = 'LightGray'
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(20, 58)
$form.Controls.Add($hint)

$list = New-Object System.Windows.Forms.ListBox
$list.Size = New-Object System.Drawing.Size(710, 300)
$list.Location = New-Object System.Drawing.Point(20, 90)
$list.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 45)
$list.ForeColor = 'White'
$form.Controls.Add($list)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Scanning keyboards...'
$status.ForeColor = 'LightGreen'
$status.AutoSize = $true
$status.Location = New-Object System.Drawing.Point(20, 410)
$form.Controls.Add($status)

$restoreInfo = New-Object System.Windows.Forms.Label
$restoreInfo.Text = 'Mouse-only restore shortcut will be created on desktop.'
$restoreInfo.ForeColor = 'LightGray'
$restoreInfo.AutoSize = $true
$restoreInfo.Location = New-Object System.Drawing.Point(20, 435)
$form.Controls.Add($restoreInfo)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh'
$btnRefresh.Size = New-Object System.Drawing.Size(120, 40)
$btnRefresh.Location = New-Object System.Drawing.Point(20, 470)
$form.Controls.Add($btnRefresh)

$btnDisable = New-Object System.Windows.Forms.Button
$btnDisable.Text = 'Disable Selected Internal'
$btnDisable.Size = New-Object System.Drawing.Size(230, 40)
$btnDisable.Location = New-Object System.Drawing.Point(160, 470)
$btnDisable.BackColor = 'DarkRed'
$btnDisable.ForeColor = 'White'
$form.Controls.Add($btnDisable)

$btnEnableSaved = New-Object System.Windows.Forms.Button
$btnEnableSaved.Text = 'Re-enable Saved Devices'
$btnEnableSaved.Size = New-Object System.Drawing.Size(210, 40)
$btnEnableSaved.Location = New-Object System.Drawing.Point(410, 470)
$btnEnableSaved.BackColor = 'DarkGreen'
$btnEnableSaved.ForeColor = 'White'
$form.Controls.Add($btnEnableSaved)

$script:keyboardRows = @()

function Load-Keyboards {
    $list.Items.Clear()
    $script:keyboardRows = @()

    try {
        $devices = Get-PnpDevice -Class Keyboard -ErrorAction Stop

        foreach ($dev in $devices) {
            $isInternal = Test-IsLikelyInternalKeyboard -Device $dev
            $scopeText = if ($isInternal) { 'LIKELY INTERNAL' } else { 'EXTERNAL/UNKNOWN (BLOCKED)' }
            $line = "[{0}] {1}  |  {2}" -f $scopeText, $dev.FriendlyName, $dev.Status
            $list.Items.Add($line) | Out-Null
            $script:keyboardRows += [PSCustomObject]@{
                InstanceId = [string]$dev.InstanceId
                FriendlyName = [string]$dev.FriendlyName
                IsLikelyInternal = [bool]$isInternal
            }
        }

        $status.Text = "Found $($devices.Count) keyboard device(s)."
    }
    catch {
        $status.Text = "Failed to enumerate keyboards: $($_.Exception.Message)"
    }
}

Ensure-RestoreAssets
Load-Keyboards

$btnRefresh.Add_Click({
    Load-Keyboards
})

$btnDisable.Add_Click({
    if ($list.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a keyboard first.", "Internal Keyboard Disabler")
        return
    }

    $selected = $script:keyboardRows[$list.SelectedIndex]
    if (-not $selected.IsLikelyInternal) {
        [System.Windows.Forms.MessageBox]::Show(
            "Selected device is not considered internal. This safety check protects external keyboards and other input devices.",
            "Safety Block"
        )
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Disable this internal keyboard?`n`n$($selected.FriendlyName)`n$($selected.InstanceId)`n`nUse the desktop restore shortcut to revert with mouse only.",
        "Confirm Disable",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        Disable-KeyboardById -instanceId $selected.InstanceId
        $current = Read-DisabledState
        Write-DisabledState -instanceIds ($current + @($selected.InstanceId))
        $status.Text = "Disabled: $($selected.FriendlyName). Change is persisted until re-enabled."
        Load-Keyboards
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to disable keyboard: $($_.Exception.Message)", "Error")
    }
})

$btnEnableSaved.Add_Click({
    try {
        $ids = Read-DisabledState
        if ($ids.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No saved disabled keyboards to restore.", "Restore")
            return
        }

        foreach ($id in $ids) {
            Enable-KeyboardById -instanceId $id
        }

        Write-DisabledState -instanceIds @()
        $status.Text = "Re-enabled all saved keyboard devices."
        Load-Keyboards
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Restore failed: $($_.Exception.Message)", "Error")
    }
})

try {
    [void]$form.ShowDialog()
}
catch {
    Write-Host ""
    Write-Host "[RUNTIME ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    pause
}
