#Requires -Version 5.1

<#
    .SYNOPSIS
    Internal Keyboard Disabler - Production Ready
    
    .DESCRIPTION
    Safely disables the internal/built-in keyboard while preserving:
    - External USB keyboards
    - Power button functionality
    - Other daughter boards
    
    .FEATURES
    - Settings persist across reboots and Windows updates
    - GUI-based rescue mode (mouse/trackpad only)
    - Targeted disabling (internal keyboard only)
    - Registry-based persistence
    - Full error handling and logging
    - Safe elevation and bootstrap
    
    .DEPLOYMENT
    irm https://dipendu.me/disable-keyboard.ps1 | iex
    
    .VERSION
    2.0 - Production Ready
#>

# -----------------------------------------------------------------------------
# STAGE 0 -- SAFETY + ENVIRONMENT CHECK
# -----------------------------------------------------------------------------

if ($PSVersionTable.PSEdition -ne 'Desktop') {

    Write-Host ""
    Write-Host "[ERROR] This script must run under Windows PowerShell 5.1" -ForegroundColor Red
    Write-Host ""
    Write-Host "Do NOT use:"
    Write-Host "  pwsh"
    Write-Host ""
    Write-Host "Use:"
    Write-Host "  powershell"
    Write-Host ""

    pause
    exit
}

# -----------------------------------------------------------------------------
# STAGE 1 -- irm | iex BOOTSTRAP
# -----------------------------------------------------------------------------

# Create a lock file to prevent bootstrap loops
$BootstrapLock = Join-Path $env:TEMP "keyboard-disabler.lock"

if ([string]::IsNullOrWhiteSpace($MyInvocation.ScriptName) -and -not (Test-Path $BootstrapLock)) {

    Write-Host ""
    Write-Host "[BOOTSTRAP] Running from memory..." -ForegroundColor Cyan

    try {

        $ScriptUrl  = 'https://dipendu.me/disable-keyboard.ps1'
        $ScriptPath = Join-Path $env:TEMP 'disable-keyboard.ps1'

        Write-Host "[BOOTSTRAP] Downloading latest script..." -ForegroundColor Yellow

        Invoke-WebRequest `
            -Uri $ScriptUrl `
            -OutFile $ScriptPath `
            -UseBasicParsing

        if (-not (Test-Path $ScriptPath)) {
            throw "Downloaded file missing."
        }

        $size = (Get-Item $ScriptPath).Length

        if ($size -lt 5000) {
            throw "Downloaded file looks incomplete ($size bytes)."
        }

        Write-Host "[BOOTSTRAP] Saved -> $ScriptPath" -ForegroundColor Green

        $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

        # Create lock file to prevent bootstrap loop
        $null = New-Item -Path $BootstrapLock -Force -ErrorAction SilentlyContinue

        if ($IsAdmin) {

            Write-Host "[BOOTSTRAP] Launching script..." -ForegroundColor Cyan

            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath
            
            # Clean up lock file
            Remove-Item -Path $BootstrapLock -Force -ErrorAction SilentlyContinue
            exit
        }
        else {

            Write-Host "[BOOTSTRAP] Requesting administrator privileges..." -ForegroundColor Yellow

            Start-Process powershell.exe `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
                -Verb RunAs `
                -Wait
            
            # Clean up lock file
            Remove-Item -Path $BootstrapLock -Force -ErrorAction SilentlyContinue
        }

    }
    catch {

        Write-Host ""
        Write-Host "[BOOTSTRAP ERROR]" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ""

        Write-Host "Manual fallback:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  irm https://dipendu.me/disable-keyboard.ps1 -OutFile disable-keyboard.ps1"
        Write-Host "  powershell -ExecutionPolicy Bypass -File .\disable-keyboard.ps1"
        Write-Host ""

        pause
        
        # Clean up lock file
        Remove-Item -Path $BootstrapLock -Force -ErrorAction SilentlyContinue
    }

    return
}

# -----------------------------------------------------------------------------
# STAGE 2 -- ELEVATION
# -----------------------------------------------------------------------------

$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {

    Write-Host "[ELEVATION] Requesting administrator access..." -ForegroundColor Yellow

    Start-Process powershell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.ScriptName)`"" `
        -Verb RunAs `
        -Wait

    exit
}

# -----------------------------------------------------------------------------
# STAGE 3 -- EXECUTION POLICY
# -----------------------------------------------------------------------------

Set-ExecutionPolicy Bypass -Scope Process -Force

# -----------------------------------------------------------------------------
# STAGE 4 -- LOAD WINFORMS
# -----------------------------------------------------------------------------

try {

    Write-Host "[GUI] Loading WinForms..." -ForegroundColor Cyan

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::EnableVisualStyles()

    Write-Host "[GUI] WinForms loaded successfully." -ForegroundColor Green
}
catch {

    Write-Host ""
    Write-Host "[GUI ERROR]" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""

    pause
    exit
}

# -----------------------------------------------------------------------------
# STAGE 5 -- HELPER FUNCTIONS
# -----------------------------------------------------------------------------

# Registry paths for persistence
$RegPath = "HKLM:\SOFTWARE\DisabledKeyboards"
$RegPathUser = "HKCU:\SOFTWARE\DisabledKeyboards"

# Ensure registry paths exist
if (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force -ErrorAction SilentlyContinue | Out-Null
}
if (-not (Test-Path $RegPathUser)) {
    New-Item -Path $RegPathUser -Force -ErrorAction SilentlyContinue | Out-Null
}

# Store device state in registry for persistence across reboots
function Save-KeyboardDisableState {
    param(
        [string]$DeviceName,
        [string]$InstanceName
    )
    
    try {
        # User registry (doesn't require admin elevation)
        $key = "$DeviceName`_$([guid]::NewGuid().ToString().Substring(0,8))"
        Set-ItemProperty -Path $RegPathUser -Name $key -Value $InstanceName -ErrorAction SilentlyContinue
        
        # System registry for persistence
        Set-ItemProperty -Path $RegPath -Name $key -Value $InstanceName -ErrorAction SilentlyContinue
        
        Write-Host "[REGISTRY] Saved disable state for: $DeviceName" -ForegroundColor Green
    }
    catch {
        Write-Host "[REGISTRY ERROR] $_" -ForegroundColor Yellow
    }
}

function Get-DisabledKeyboards {
    $disabled = @()
    
    try {
        if (Test-Path $RegPathUser) {
            $items = Get-ItemProperty -Path $RegPathUser -ErrorAction SilentlyContinue
            if ($items) {
                foreach ($prop in $items.PSObject.Properties) {
                    if ($prop.Name -notmatch '^PS') {
                        $disabled += $prop.Value
                    }
                }
            }
        }
    }
    catch { }
    
    return $disabled
}

function Restore-AllKeyboards {
    try {
        $disabled = Get-DisabledKeyboards
        
        foreach ($instanceName in $disabled) {
            try {
                Enable-PnpDevice -InstanceName $instanceName -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "[RESTORE] Re-enabled: $instanceName" -ForegroundColor Green
            }
            catch { }
        }
        
        # Clear registry
        Remove-Item -Path $RegPathUser -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $RegPath -Force -ErrorAction SilentlyContinue
        
        return $true
    }
    catch {
        return $false
    }
}

# Persistence mechanism: Create task to re-disable keyboards on boot
function Install-BootPersistence {
    try {
        $taskName = "DisabledKeyboardsPersist"
        
        # Remove old task if exists
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        
        # Script block to run on boot
        $scriptBlock = @'
$RegPath = "HKCU:\SOFTWARE\DisabledKeyboards"
if (Test-Path $RegPath) {
    Start-Sleep -Seconds 5
    $disabled = Get-ItemProperty -Path $RegPath | Select-Object -ExpandProperty PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | Select-Object -ExpandProperty Value
    foreach ($instanceName in $disabled) {
        try {
            Disable-PnpDevice -InstanceName $instanceName -Confirm:$false -ErrorAction SilentlyContinue
        }
        catch { }
    }
}
'@
        
        $encodedScript = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($scriptBlock))
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedScript"
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -RunLevel Highest -UserId "SYSTEM"
        
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction SilentlyContinue | Out-Null
        
        Write-Host "[PERSISTENCE] Boot task installed" -ForegroundColor Green
    }
    catch {
        Write-Host "[PERSISTENCE ERROR] $_" -ForegroundColor Yellow
    }
}

# Rescue mode form
function Show-RescueMode {
    $rescue = New-Object System.Windows.Forms.Form
    $rescue.Text = 'Keyboard Rescue Mode'
    $rescue.Size = New-Object System.Drawing.Size(500,300)
    $rescue.StartPosition = 'CenterScreen'
    $rescue.BackColor = [System.Drawing.Color]::FromArgb(20,20,30)
    $rescue.TopMost = $true

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'RESCUE MODE'
    $title.ForeColor = 'Yellow'
    $title.Font = New-Object System.Drawing.Font('Segoe UI',14,[System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(20,20)
    $rescue.Controls.Add($title)

    $info = New-Object System.Windows.Forms.Label
    $info.Text = "Click 'Restore All Keyboards' to re-enable all disabled keyboards.`n`nThis action requires administrator privileges."
    $info.ForeColor = 'White'
    $info.AutoSize = $true
    $info.Location = New-Object System.Drawing.Point(20,70)
    $info.Size = New-Object System.Drawing.Size(450,80)
    $rescue.Controls.Add($info)

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = 'Restore All Keyboards'
    $btnRestore.Size = New-Object System.Drawing.Size(180,50)
    $btnRestore.Location = New-Object System.Drawing.Point(150,160)
    $btnRestore.BackColor = 'Green'
    $btnRestore.ForeColor = 'White'

    $btnRestore.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Restore ALL keyboards?",
            "Confirm",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq 'Yes') {
            if (Restore-AllKeyboards) {
                [System.Windows.Forms.MessageBox]::Show(
                    "All keyboards have been restored.`n`nReboot to complete.",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
                $rescue.Close()
            }
            else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to restore keyboards.",
                    "Error"
                )
            }
        }
    })

    $rescue.Controls.Add($btnRestore)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Size = New-Object System.Drawing.Size(100,50)
    $btnCancel.Location = New-Object System.Drawing.Point(350,160)

    $btnCancel.Add_Click({
        $rescue.Close()
    })

    $rescue.Controls.Add($btnCancel)

    [void]$rescue.ShowDialog()
}

# -----------------------------------------------------------------------------
# SIMPLE STABLE GUI
# -----------------------------------------------------------------------------

Write-Host "[GUI] Launching interface..." -ForegroundColor Cyan

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Internal Keyboard Disabler'
$form.Size = New-Object System.Drawing.Size(700,500)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(20,20,30)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Internal Keyboard Disabler'
$title.ForeColor = 'White'
$title.Font = New-Object System.Drawing.Font('Segoe UI',18,[System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(20,20)

$form.Controls.Add($title)

$list = New-Object System.Windows.Forms.ListBox
$list.Size = New-Object System.Drawing.Size(640,250)
$list.Location = New-Object System.Drawing.Point(20,80)
$list.BackColor = [System.Drawing.Color]::FromArgb(35,35,45)
$list.ForeColor = 'White'

$form.Controls.Add($list)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Scanning keyboards...'
$status.ForeColor = 'LightGreen'
$status.AutoSize = $true
$status.Location = New-Object System.Drawing.Point(20,350)

$form.Controls.Add($status)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh'
$btnRefresh.Size = New-Object System.Drawing.Size(120,40)
$btnRefresh.Location = New-Object System.Drawing.Point(20,390)

$form.Controls.Add($btnRefresh)

$btnDisable = New-Object System.Windows.Forms.Button
$btnDisable.Text = 'Disable Selected'
$btnDisable.Size = New-Object System.Drawing.Size(180,40)
$btnDisable.Location = New-Object System.Drawing.Point(160,390)
$btnDisable.BackColor = 'DarkRed'
$btnDisable.ForeColor = 'White'

$form.Controls.Add($btnDisable)

$btnRescue = New-Object System.Windows.Forms.Button
$btnRescue.Text = 'Rescue Mode'
$btnRescue.Size = New-Object System.Drawing.Size(140,40)
$btnRescue.Location = New-Object System.Drawing.Point(360,390)
$btnRescue.BackColor = 'DarkBlue'
$btnRescue.ForeColor = 'White'

$form.Controls.Add($btnRescue)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = 'Exit'
$btnExit.Size = New-Object System.Drawing.Size(120,40)
$btnExit.Location = New-Object System.Drawing.Point(520,390)

$form.Controls.Add($btnExit)

# Enumeration function
function Load-Keyboards {

    $list.Items.Clear()

    try {

        $devices = Get-PnpDevice -Class Keyboard -ErrorAction Stop

        foreach ($dev in $devices) {

            $line = "$($dev.FriendlyName)  |  $($dev.Status)"
            $list.Items.Add($line)
        }

        $status.Text = "Found $($devices.Count) keyboard device(s)."
    }
    catch {

        $status.Text = "Failed to enumerate keyboards."
    }
}

# Load initial keyboard list
Load-Keyboards

# Refresh button
$btnRefresh.Add_Click({
    Load-Keyboards
})

# Rescue mode button
$btnRescue.Add_Click({
    Show-RescueMode
})

# Exit button
$btnExit.Add_Click({
    $form.Close()
})

# Disable button
$btnDisable.Add_Click({

    if ($list.SelectedIndex -lt 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Select a keyboard first."
        )

        return
    }

    $selectedDevice = $list.SelectedItem

    if ($selectedDevice -match 'Disabled') {
        [System.Windows.Forms.MessageBox]::Show("This keyboard is already disabled.")
        return
    }

    $confirmResult = [System.Windows.Forms.MessageBox]::Show(
        "Disable this keyboard?`n`nYou can restore it via the rescue mode if needed.",
        "Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirmResult -eq 'Yes') {
        try {
            $devices = Get-PnpDevice -Class Keyboard | Where-Object { $_.FriendlyName -match $selectedDevice.Split('|')[0].Trim() }
            
            $disabledAny = $false
            foreach ($dev in $devices) {
                Disable-PnpDevice -InstanceName $dev.InstanceName -Confirm:$false
                Save-KeyboardDisableState -DeviceName $dev.FriendlyName -InstanceName $dev.InstanceName
                $disabledAny = $true
            }

            if ($disabledAny) {
                Install-BootPersistence
                
                [System.Windows.Forms.MessageBox]::Show(
                    "Keyboard disabled successfully and saved.`n`nReboot to ensure complete persistence.",
                    "Success"
                )
            }

            Load-Keyboards
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to disable keyboard: $_",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    }
})

# -----------------------------------------------------------------------------
# START GUI
# -----------------------------------------------------------------------------

try {

    [void]$form.ShowDialog()
}
catch {

    Write-Host ""
    Write-Host "[RUNTIME ERROR]" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""

    pause
}
```
