```powershell
#Requires -Version 5.1

<#
    Internal Keyboard Disabler
    Stable bootstrap + GUI-safe launcher edition

    Designed specifically for:
      irm https://dipendu.me/disable-keyboard.ps1 | iex

    This version fixes:
      - silent exits
      - detached background PowerShell launches
      - PowerShell 7 incompatibility
      - hidden GUI failures
      - bootstrap crashes
      - missing visibility/debugging
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

if ([string]::IsNullOrWhiteSpace($MyInvocation.ScriptName)) {

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

        $IsAdmin = (
            [Security.Principal.WindowsPrincipal]
            [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )

        $cmd = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

        if ($IsAdmin) {

            Write-Host "[BOOTSTRAP] Launching script..." -ForegroundColor Cyan

            powershell.exe $cmd
        }
        else {

            Write-Host "[BOOTSTRAP] Requesting administrator privileges..." -ForegroundColor Yellow

            Start-Process powershell.exe `
                -ArgumentList $cmd `
                -Verb RunAs `
                -Wait
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
    }

    return
}

# -----------------------------------------------------------------------------
# STAGE 2 -- ELEVATION
# -----------------------------------------------------------------------------

$IsAdmin = (
    [Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

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

# -----------------------------------------------------------------------------
# ENUMERATION
# -----------------------------------------------------------------------------

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

Load-Keyboards

$btnRefresh.Add_Click({
    Load-Keyboards
})

$btnDisable.Add_Click({

    if ($list.SelectedIndex -lt 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Select a keyboard first."
        )

        return
    }

    [System.Windows.Forms.MessageBox]::Show(
        "Disable logic placeholder.`n`nYour stable GUI/bootstrap is now confirmed working.",
        "Success"
    )
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
