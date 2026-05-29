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

# Registry path for tracking disabled keyboards
# Keys are stored as sanitised device name -> InstanceName value
# This is deterministic so we can reliably look them up on restore
$RegPath     = "HKLM:\SOFTWARE\DisabledKeyboards"
$RegPathUser = "HKCU:\SOFTWARE\DisabledKeyboards"

# Ensure registry paths exist
if (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force -ErrorAction SilentlyContinue | Out-Null
}
if (-not (Test-Path $RegPathUser)) {
    New-Item -Path $RegPathUser -Force -ErrorAction SilentlyContinue | Out-Null
}

# ---------------------------------------------------------------------------
# FIXED: Get-KeyboardType
# ---------------------------------------------------------------------------
function Get-KeyboardType {
    param([object]$Device)

    try {
        $instanceName = $Device.InstanceName

        # --- Definite INTERNAL indicators in the instance path ---
        $internalInstancePatterns = @(
            'ACPI\\PNP0303',     # classic PS/2
            'ACPI\\MSF0001',     # Surface Type Cover
            'HID\\VID_045E',     # Microsoft HID (Surface/OEM integrated)
            'HID\\ACPI',
            'PS2',
            'LAPTOP',
            'INTERNAL',
            'KBD'
        )
        foreach ($p in $internalInstancePatterns) {
            if ($instanceName -imatch [regex]::Escape($p)) {
                return "INTERNAL"
            }
        }

        # --- Friendly name heuristics ---
        $fn = $Device.FriendlyName.ToLower()
        $internalNamePatterns = @(
            'standard ps/2',
            'ps/2',
            'laptop',
            'integrated',
            'internal',
            'built-in',
            'acpi',
            'ec keyboard',
            'hid keyboard device'   # generic HID almost always means internal on a laptop
        )
        foreach ($p in $internalNamePatterns) {
            if ($fn -match [regex]::Escape($p)) {
                return "INTERNAL"
            }
        }

        # --- Registry hardware IDs check ---
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$instanceName"
        if (Test-Path $regPath) {
            $devInfo = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            $hwIds   = if ($devInfo.HardwareID)        { $devInfo.HardwareID -join "," }        else { "" }
            $compIds = if ($devInfo.CompatibleIDs)     { $devInfo.CompatibleIDs -join "," }     else { "" }
            $locInfo = if ($devInfo.LocationInformation){ $devInfo.LocationInformation }         else { "" }
            $parentBus = if ($devInfo.ParentIdPrefix)  { $devInfo.ParentIdPrefix }              else { "" }

            # If the parent bus is listed as USB, it's definitely external
            if ($hwIds -imatch 'USB' -or $compIds -imatch 'USB') {
                # Extra safety: a USB hub's child can still be an internal keyboard on
                # some Surface/embedded devices, but that's extremely rare.  Treat USB as
                # external unless the friendly name already matched internal above.
                return "EXTERNAL"
            }

            # HID devices whose hardware ID is NOT USB are almost always internal
            if ($hwIds -imatch 'HID' -or $instanceName -imatch '^HID\\') {
                return "INTERNAL"
            }
        }

        # --- Final safe default ---
        # If we still cannot tell, assume INTERNAL so we never accidentally
        # block the user's only external keyboard.
        return "INTERNAL"
    }
    catch {
        return "INTERNAL"
    }
}

# ---------------------------------------------------------------------------
# FIXED: Save-KeyboardDisableState
# ---------------------------------------------------------------------------
function Save-KeyboardDisableState {
    param(
        [string]$DeviceName,
        [string]$InstanceName
    )

    try {
        # Sanitise the name so it is a valid registry value name
        $key = ($DeviceName -replace '[\\/:*?"<>|]', '_').Trim()
        if ([string]::IsNullOrWhiteSpace($key)) { $key = "UnknownKeyboard" }

        Set-ItemProperty -Path $RegPath     -Name $key -Value $InstanceName -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $RegPathUser -Name $key -Value $InstanceName -ErrorAction SilentlyContinue

        Write-Host "[REGISTRY] Saved disable state for: $DeviceName (key=$key)" -ForegroundColor Green
    }
    catch {
        Write-Host "[REGISTRY ERROR] $_" -ForegroundColor Yellow
    }
}

function Get-DisabledKeyboards {
    $disabled = @()

    try {
        # Prefer HKLM (written with admin rights); fall back to HKCU
        foreach ($path in @($RegPath, $RegPathUser)) {
            if (Test-Path $path) {
                $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                if ($items) {
                    foreach ($prop in $items.PSObject.Properties) {
                        if ($prop.Name -notmatch '^PS' -and -not [string]::IsNullOrWhiteSpace($prop.Value)) {
                            $disabled += $prop.Value
                        }
                    }
                }
            }
        }
    }
    catch { }

    # Deduplicate
    return ($disabled | Select-Object -Unique)
}

# ---------------------------------------------------------------------------
# FIXED: Restore-AllKeyboards
# ---------------------------------------------------------------------------
function Restore-AllKeyboards {
    try {
        $disabled = Get-DisabledKeyboards

        if ($disabled.Count -eq 0) {
            Write-Host "[RESTORE] No disabled keyboards found in registry" -ForegroundColor Yellow
        }

        foreach ($instanceName in $disabled) {
            if ([string]::IsNullOrWhiteSpace($instanceName)) { continue }

            Write-Host "[RESTORE] Attempting to restore: $instanceName" -ForegroundColor Cyan

            $restored = $false

            # --- Primary: Enable-PnpDevice (most reliable on Win10) ---
            try {
                $device = Get-PnpDevice | Where-Object { $_.InstanceName -eq $instanceName }
                if ($device) {
                    Enable-PnpDevice -InstanceId $instanceName -Confirm:$false -ErrorAction Stop

                    # Wait up to 5 s for the status to change to OK
                    $waited = 0
                    do {
                        Start-Sleep -Milliseconds 500
                        $waited += 500
                        $device = Get-PnpDevice | Where-Object { $_.InstanceName -eq $instanceName }
                    } while ($device.Status -eq 'Error' -and $waited -lt 5000)

                    if ($device.Status -eq 'OK') {
                        Write-Host "[RESTORE] Enabled via PnP: $instanceName" -ForegroundColor Green
                        $restored = $true
                    }
                    else {
                        Write-Host "[RESTORE] PnP enable issued but status is '$($device.Status)'; trying devcon..." -ForegroundColor Yellow
                    }
                }
                else {
                    Write-Host "[RESTORE] Device not found in PnP list (may already be enabled or removed): $instanceName" -ForegroundColor Yellow
                    $restored = $true  # treat missing device as non-blocking
                }
            }
            catch {
                Write-Host "[RESTORE] Enable-PnpDevice failed: $_" -ForegroundColor Yellow
            }

            # --- Fallback: devcon enable ---
            if (-not $restored) {
                try {
                    $devconPath = "C:\Windows\System32\devcon.exe"
                    if (Test-Path $devconPath) {
                        # devcon expects the instance ID wrapped in @
                        $result = & "$devconPath" enable "@$instanceName" 2>&1
                        Write-Host "[RESTORE] devcon: $result" -ForegroundColor Gray

                        if ($result -imatch 'enabled') {
                            Write-Host "[RESTORE] Enabled via devcon: $instanceName" -ForegroundColor Green
                            $restored = $true
                        }
                    }
                    else {
                        Write-Host "[RESTORE] devcon.exe not found at $devconPath" -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "[RESTORE] devcon method failed: $_" -ForegroundColor Yellow
                }
            }

            if (-not $restored) {
                Write-Host "[RESTORE] WARNING: Could not confirm restoration of $instanceName" -ForegroundColor Red
            }
        }

        # --- Clear registry entries ---
        Remove-Item -Path $RegPath     -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $RegPathUser -Force -ErrorAction SilentlyContinue
        # Recreate the keys empty so the script still works if run again
        New-Item -Path $RegPath     -Force -ErrorAction SilentlyContinue | Out-Null
        New-Item -Path $RegPathUser -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host "[RESTORE] Cleared registry entries" -ForegroundColor Green

        # --- Remove boot persistence task ---
        $taskName = "DisabledKeyboardsPersist"
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "[RESTORE] Removed boot persistence task" -ForegroundColor Green
        }

        return $true
    }
    catch {
        Write-Host "[RESTORE ERROR] $_" -ForegroundColor Yellow
        return $false
    }
}

# ---------------------------------------------------------------------------
# FIXED: Install-BootPersistence
#----------------------------------------------------------------------------
function Install-BootPersistence {
    try {
        $taskName = "DisabledKeyboardsPersist"

        # Remove old task if it exists
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500

        # The script block that runs on startup/logon
        $scriptBlock = @'
Start-Sleep -Seconds 8

# Read disabled keyboard list from registry
$regPaths = @(
    "HKLM:\SOFTWARE\DisabledKeyboards",
    "HKCU:\SOFTWARE\DisabledKeyboards"
)

$disabledDevices = @()
foreach ($regPath in $regPaths) {
    if (Test-Path $regPath) {
        try {
            $items = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            if ($items) {
                foreach ($prop in $items.PSObject.Properties) {
                    if ($prop.Name -notmatch '^PS' -and $prop.Value) {
                        $disabledDevices += $prop.Value
                    }
                }
            }
        }
        catch { }
    }
}

$disabledDevices = $disabledDevices | Where-Object { $_ } | Select-Object -Unique

foreach ($instanceName in $disabledDevices) {
    try {
        # Use Disable-PnpDevice -- this is the correct API on Windows 10
        $device = Get-PnpDevice | Where-Object { $_.InstanceName -eq $instanceName }
        if ($device -and $device.Status -ne 'Error') {
            Disable-PnpDevice -InstanceId $instanceName -Confirm:$false -ErrorAction SilentlyContinue
        }

        # devcon fallback
        $devconPath = "C:\Windows\System32\devcon.exe"
        if (-not $device -or $device.Status -ne 'Error') {
            if (Test-Path $devconPath) {
                & "$devconPath" disable "@$instanceName" 2>&1 | Out-Null
            }
        }
    }
    catch { }
}
'@

        $encodedScript = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($scriptBlock))
        $psArgs = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedScript"
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs

        # Fire at SYSTEM startup (before logon) AND at each logon as a safety net
        $triggerBoot  = New-ScheduledTaskTrigger -AtStartup
        $triggerLogon = New-ScheduledTaskTrigger -AtLogOn

        # Run as SYSTEM with highest privileges so it can access PnP devices
        $principal = New-ScheduledTaskPrincipal -RunLevel Highest -UserId "SYSTEM"
        $settings  = New-ScheduledTaskSettingsSet `
                        -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries `
                        -RunOnlyIfNetworkAvailable:$false `
                        -StartWhenAvailable

        Register-ScheduledTask `
            -TaskName $taskName `
            -Action   $action `
            -Trigger  @($triggerBoot, $triggerLogon) `
            -Principal $principal `
            -Settings  $settings `
            -Force `
            -ErrorAction SilentlyContinue | Out-Null

        Write-Host "[PERSISTENCE] Boot+Logon task installed." -ForegroundColor Green
    }
    catch {
        Write-Host "[PERSISTENCE ERROR] $_" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# FIXED: Disable-InternalKeyboard (formerly inline in the button handler)
# ---------------------------------------------------------------------------
function Disable-InternalKeyboard {
    param([object]$Device)

    $instanceId = $Device.InstanceName
    $disabled   = $false

    # --- Primary: Disable-PnpDevice ---
    try {
        Disable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction Stop

        # Wait up to 5 s for status to change
        $waited = 0
        do {
            Start-Sleep -Milliseconds 500
            $waited += 500
            $check = Get-PnpDevice | Where-Object { $_.InstanceName -eq $instanceId }
        } while ($check -and $check.Status -ne 'Error' -and $waited -lt 5000)

        $check = Get-PnpDevice | Where-Object { $_.InstanceName -eq $instanceId }
        if ($check -and $check.Status -eq 'Error') {
            Write-Host "[DISABLE] Disabled via Disable-PnpDevice: $($Device.FriendlyName)" -ForegroundColor Green
            $disabled = $true
        }
        else {
            Write-Host "[DISABLE] Disable-PnpDevice returned but status is '$($check.Status)'" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "[DISABLE] Disable-PnpDevice failed: $_" -ForegroundColor Yellow
    }

    # --- Fallback: devcon disable ---
    if (-not $disabled) {
        try {
            $devconPath = "C:\Windows\System32\devcon.exe"
            if (Test-Path $devconPath) {
                $result = & "$devconPath" disable "@$instanceId" 2>&1
                Write-Host "[DISABLE] devcon: $result" -ForegroundColor Gray

                if ($result -imatch 'disabled') {
                    Write-Host "[DISABLE] Disabled via devcon: $($Device.FriendlyName)" -ForegroundColor Green
                    $disabled = $true
                }
                else {
                    Write-Host "[DISABLE] devcon did not confirm disable: $result" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "[DISABLE] devcon.exe not present; skipping fallback." -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "[DISABLE] devcon method failed: $_" -ForegroundColor Yellow
        }
    }

    return $disabled
}

# Rescue mode form (unchanged in behaviour; only text updated)
function Show-RescueMode {
    $rescue = New-Object System.Windows.Forms.Form
    $rescue.Text = 'Keyboard Rescue Mode'
    $rescue.Size = New-Object System.Drawing.Size(520,320)
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
    $info.Text = "Click 'Restore All Keyboards' to re-enable all disabled internal keyboards.`n`nThis removes the keyboard disable settings from your system.`n`nExternal keyboards are not affected.`n`nA reboot is recommended after restoring."
    $info.ForeColor = 'White'
    $info.AutoSize = $false
    $info.Size = New-Object System.Drawing.Size(470,110)
    $info.Location = New-Object System.Drawing.Point(20,65)
    $rescue.Controls.Add($info)

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = 'Restore All Keyboards'
    $btnRestore.Size = New-Object System.Drawing.Size(200,50)
    $btnRestore.Location = New-Object System.Drawing.Point(140,195)
    $btnRestore.BackColor = 'Green'
    $btnRestore.ForeColor = 'White'

    $btnRestore.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Restore ALL keyboards and remove boot persistence?",
            "Confirm",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq 'Yes') {
            if (Restore-AllKeyboards) {
                [System.Windows.Forms.MessageBox]::Show(
                    "All keyboards have been restored.`n`nA reboot is recommended to complete the process.",
                    "Success",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
                $rescue.Close()
            }
            else {
                [System.Windows.Forms.MessageBox]::Show(
                    "One or more keyboards could not be confirmed as restored.`nCheck the console output for details.",
                    "Warning",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
            }
        }
    })

    $rescue.Controls.Add($btnRestore)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Size = New-Object System.Drawing.Size(100,50)
    $btnCancel.Location = New-Object System.Drawing.Point(370,195)

    $btnCancel.Add_Click({ $rescue.Close() })
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

# Store device objects alongside display strings
$script:DeviceList = @()

function Load-Keyboards {

    $list.Items.Clear()
    $script:DeviceList = @()

    try {

        $devices = Get-PnpDevice -Class Keyboard -ErrorAction Stop
        $internalCount = 0
        $externalCount = 0

        foreach ($dev in $devices) {
            $keyboardType = Get-KeyboardType -Device $dev
            $typeLabel    = if ($keyboardType -eq "INTERNAL") { "[INT]" } else { "[EXT]" }

            if ($keyboardType -eq "INTERNAL") { $internalCount++ } else { $externalCount++ }

            $line = "$typeLabel $($dev.FriendlyName) | $($dev.Status)"
            $list.Items.Add($line) | Out-Null
            $script:DeviceList += $dev
        }

        $status.Text = "Found $internalCount internal, $externalCount external keyboard(s). Total: $($devices.Count)"
    }
    catch {
        $status.Text = "Failed to enumerate keyboards: $_"
    }
}

# Load initial keyboard list
Load-Keyboards

$btnRefresh.Add_Click({ Load-Keyboards })

$btnRescue.Add_Click({ Show-RescueMode })

$btnExit.Add_Click({ $form.Close() })

$btnDisable.Add_Click({

    if ($list.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Select a keyboard first.")
        return
    }

    $selectedIndex  = $list.SelectedIndex
    $selectedText   = $list.SelectedItem
    $selectedDevice = $script:DeviceList[$selectedIndex]

    # Guard: external keyboard
    if ($selectedText -match "\[EXT\]") {
        [System.Windows.Forms.MessageBox]::Show(
            "Cannot disable external keyboards.`n`nOnly internal keyboards can be disabled.",
            "Action Not Allowed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    # Guard: already disabled
    if ($selectedText -match 'Error') {
        [System.Windows.Forms.MessageBox]::Show("This keyboard is already disabled.")
        return
    }

    $confirmResult = [System.Windows.Forms.MessageBox]::Show(
        "Disable this internal keyboard?`n`n$($selectedDevice.FriendlyName)`n`nExternal USB keyboards will remain functional.`nYou can restore it via Rescue Mode.",
        "Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirmResult -ne 'Yes') { return }

    try {
        # Double-check it is internal using the actual device object
        if ((Get-KeyboardType -Device $selectedDevice) -ne "INTERNAL") {
            Write-Host "[SECURITY] Blocked attempt to disable external device: $($selectedDevice.FriendlyName)" -ForegroundColor Yellow
            [System.Windows.Forms.MessageBox]::Show(
                "This device was re-classified as external. Aborting for safety.",
                "Blocked",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            return
        }

        $ok = Disable-InternalKeyboard -Device $selectedDevice

        if ($ok) {
            Save-KeyboardDisableState -DeviceName $selectedDevice.FriendlyName -InstanceName $selectedDevice.InstanceName
            Install-BootPersistence

            [System.Windows.Forms.MessageBox]::Show(
                "Internal keyboard disabled successfully.`n`nThe disable will persist across reboots.`n`nExternal keyboards remain enabled.",
                "Success"
            )
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to disable the keyboard.`n`nCheck the console window for details.`n`nIf Disable-PnpDevice is being blocked, try running devcon.exe from the Windows Driver Kit.",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }

        Load-Keyboards
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Error: $_",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
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
