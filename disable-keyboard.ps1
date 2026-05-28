# +-------------------------------------------------------------------------+
# |  Internal Keyboard Disabler  v4.0                                       |
# |  Usage:  irm https://myname.me/disable-keyboard.ps1 | iex                            |
# |  Run from an admin PowerShell window, or it will self-elevate.          |
# +-------------------------------------------------------------------------+
#
# WHAT CHANGED FROM v3.0
# ----------------------
# BUG FIX (CRITICAL)  --  Layer 3 UpperFilters "KbdBlock" REMOVED.
#   KbdBlock is a phantom driver that doesn't exist on any Windows install.
#   Windows would fail to load the driver for EVERY keyboard in the class,
#   including external USB keyboards  --  exactly the opposite of what was wanted.
#   Replaced with a SYSTEM scheduled task (safe, device-specific, persistent).
#
# BUG FIX (CRITICAL)  --  No persistence against Windows Update.
#   Layer 1 (PnP disable) can be silently re-enabled by Windows Update or
#   driver reinstallation.  Scheduled task at startup re-disables by InstanceId.
#
# BUG FIX (CRITICAL)  --  Revert didn't remove the scheduled task.
#   After reverting, the re-disable task would fire on next boot and re-block
#   the keyboard again.  Revert now unregisters the task.
#
# BUG FIX  --  $MyInvocation.ScriptName null vs empty-string.
#   Original: -eq ''  fails when ScriptName is $null.
#   Fixed: [string]::IsNullOrEmpty()
#
# BUG FIX  --  DenyDeviceIDs always wrote to value name "1", overwriting any
#   existing policy entries.  Now enumerates and uses the next free slot.
#
# BUG FIX  --  Font "Cascadia Code,Consolas" is CSS syntax; WinForms ignores
#   everything after the comma.  Fixed with a proper font availability check.
#
# UX FIX  --  Emergency recovery required navigating a file-picker dialog with
#   no keyboard.  New always-visible orange panel + one-click button finds
#   the latest backup automatically  --  pure mouse operation.
#
# UX FIX  --  Auto-scan keyboards on startup so the list is populated without
#   the user needing to remember to click Refresh.
#
# UX FIX  --  Revert auto-offers the most-recent backup first; file dialog is
#   a fallback only.
#
# UX FIX  --  Internal detection improved to also catch HID-over-I2C devices
#   (newer laptops that use I2C instead of PS/2 or legacy ACPI).
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# STAGE 0 -- irm | iex bootstrap (hardened)
# -----------------------------------------------------------------------------
#
# Detect execution through:
#   irm https://site/script.ps1 | iex
#
# iex runs in-memory with no real script path, which breaks:
#   - self elevation
#   - param()
#   - scheduled task references
#   - restart/relaunch logic
#
# Solution:
#   1. Save the script to disk
#   2. Relaunch as a normal .ps1
#   3. Exit the in-memory session
#
# -----------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($MyInvocation.ScriptName)) {

    Write-Host "`n[BOOTSTRAP] Preparing local execution..." -ForegroundColor Cyan

    try {

        # ---- CONFIG ---------------------------------------------------------
        $ScriptUrl  = 'https://dipendu.me/disable-keyboard.ps1'
        $ScriptPath = Join-Path $env:TEMP 'disable-keyboard.ps1'

        # ---- DOWNLOAD -------------------------------------------------------
        Write-Host "[BOOTSTRAP] Downloading latest script..." -ForegroundColor Yellow

        Invoke-WebRequest `
            -Uri $ScriptUrl `
            -OutFile $ScriptPath `
            -UseBasicParsing

        # ---- VALIDATION -----------------------------------------------------
        if (-not (Test-Path $ScriptPath)) {
            throw "Downloaded file does not exist."
        }

        $size = (Get-Item $ScriptPath).Length

        if ($size -lt 1000) {
            throw "Downloaded file is suspiciously small ($size bytes)."
        }

        Write-Host "[BOOTSTRAP] Saved -> $ScriptPath" -ForegroundColor Green

        # ---- ELEVATION CHECK ------------------------------------------------
        $IsAdmin = (
            [Security.Principal.WindowsPrincipal]
            [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )

        # ---- RELAUNCH -------------------------------------------------------
        $args = @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-File', "`"$ScriptPath`""
        )

        if ($IsAdmin) {

            Write-Host "[BOOTSTRAP] Launching..." -ForegroundColor Cyan

            Start-Process powershell.exe `
                -ArgumentList $args

        }
        else {

            Write-Host "[BOOTSTRAP] Requesting administrator privileges..." -ForegroundColor Yellow

            Start-Process powershell.exe `
                -ArgumentList $args `
                -Verb RunAs
        }

    }
    catch {

        Write-Host "`n[BOOTSTRAP ERROR]" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red

        Write-Host "`nManual fallback:" -ForegroundColor Yellow
        Write-Host "  irm https://dipendu.me/disable-keyboard.ps1 -OutFile disable-keyboard.ps1"
        Write-Host "  powershell -ExecutionPolicy Bypass -File .\disable-keyboard.ps1"

        Pause
    }

    return
}
# -- STAGE 1: self-elevate if not already admin ------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.ScriptName)`"" `
        -Verb RunAs
    exit
}

# -- STAGE 2: relax execution policy for this process only -------------------
Set-ExecutionPolicy Bypass -Scope Process -Force

# -----------------------------------------------------------------------------
#  ASSEMBLIES
# -----------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# -----------------------------------------------------------------------------
#  GLOBALS
# -----------------------------------------------------------------------------
$script:BackupDir  = $env:TEMP
$script:BackupFile = "$script:BackupDir\KB_Backup_$(Get-Date -Format yyyyMMdd_HHmm).xml"
$script:LogFile    = "$env:TEMP\KB_Log_$(Get-Date -Format yyyyMMdd_HHmm).txt"
$script:OSEdition  = ''
$script:OSBuild    = 0
$script:IsPro      = $false
$script:TaskName   = 'KbDisabler_ReDisableOnBoot'

function Write-Log {
    param([string]$M, [string]$L = 'INFO')
    $line = "[$(Get-Date -Format HH:mm:ss)][$L] $M"
    Add-Content $script:LogFile $line -Encoding UTF8
}

# -----------------------------------------------------------------------------
#  OS DETECTION
# -----------------------------------------------------------------------------
function Get-OSInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $script:OSBuild   = [int]$os.BuildNumber
    $script:OSEdition = $os.Caption
    $script:IsPro     = $script:OSEdition -match 'Pro|Enterprise|Education'
    Write-Log "OS=$($script:OSEdition) Build=$($script:OSBuild) IsPro=$($script:IsPro)"
}

# -----------------------------------------------------------------------------
#  KEYBOARD ENUMERATION
# -----------------------------------------------------------------------------
function Get-AllKeyboards {
    try {
        Get-PnpDevice -Class Keyboard -EA SilentlyContinue |
            Where-Object { $_.Status -ne 'Unknown' } |
            Select-Object FriendlyName, InstanceId, Status
    } catch { @() }
}

function Test-IsLikelyInternal($dev) {
    $id  = $dev.InstanceId
    $nm  = $dev.FriendlyName
    # PS/2 and ACPI-attached keyboards are always internal
    if ($id -match 'ACPI\\|PNP0303|PNP030B') { return $true }
    # Legacy name hints
    if ($nm -match 'PS/2|Standard|i8042')     { return $true }
    # HID-over-I2C (Surface, newer Acer/Dell/HP)  --  contains I2C in the path
    if ($id -match 'I2C\\')                   { return $true }
    # HID device that is NOT on USB  --  likely soldered internal HID-over-I2C
    if ($id -match '^HID\\' -and $id -notmatch 'USB') { return $true }
    return $false
}

# Return the most-recent KB_Backup*.xml in %TEMP%
function Get-LatestBackup {
    Get-ChildItem "$script:BackupDir\KB_Backup*.xml" -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

# -----------------------------------------------------------------------------
#  BACKUP
# -----------------------------------------------------------------------------
function Save-Backup($dev) {
    $b = @{
        Timestamp    = (Get-Date).ToString('o')
        InstanceId   = $dev.InstanceId
        FriendlyName = $dev.FriendlyName
        RegI8042     = $null
        GPOSet       = $false
        TaskCreated  = $false
    }
    try { $b.RegI8042 = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\i8042prt' -Name Start -EA Stop).Start } catch {}
    $b | Export-Clixml $script:BackupFile -Force
    Write-Log "Backup saved -> $($script:BackupFile)"
    return $script:BackupFile
}

# -----------------------------------------------------------------------------
#  DISABLE  (all layers  --  all device-specific, external keyboard is safe)
# -----------------------------------------------------------------------------
function Disable-InternalKeyboard($dev, [ref]$msgs) {
    $out = [System.Collections.Generic.List[string]]::new()
    $ok  = $false

    # -- Layer 1 - PnP device disable (immediate, device-specific) ------------
    try {
        Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -EA Stop
        $out.Add('[OK] Layer 1  --  Device Manager: internal keyboard disabled.')
        Write-Log "L1 PnP disabled: $($dev.InstanceId)"
        $ok = $true
    } catch {
        $out.Add("[!!] Layer 1  --  PnP disable failed: $_")
        Write-Log "L1 PnP fail: $_" 'WARN'
    }

    # -- Layer 2 - i8042prt registry (PS/2 / legacy; USB keyboards unaffected) -
    # i8042prt is the PS/2 port driver.  USB keyboards use usbhid, not i8042prt,
    # so setting Start=4 here cannot touch an external USB keyboard.
    try {
        $rp = 'HKLM:\SYSTEM\CurrentControlSet\Services\i8042prt'
        if (Test-Path $rp) {
            Set-ItemProperty $rp -Name Start -Value 4 -Type DWord -Force
            $out.Add('[OK] Layer 2  --  PS/2 driver (i8042prt) disabled in registry. Survives reboot.')
            Write-Log 'L2 i8042prt Start=4'
            $ok = $true
        } else {
            $out.Add('[--] Layer 2  --  i8042prt not present (HID-over-I2C device). Covered by Layers 1 & 3.')
        }
    } catch {
        $out.Add("[!!] Layer 2  --  i8042prt registry write failed: $_")
        Write-Log "L2 i8042prt fail: $_" 'WARN'
    }

    # -- Layer 3 - Scheduled task: re-disable the SPECIFIC device on every boot -
    #
    # WHY THIS REPLACES THE OLD UpperFilters "KbdBlock" APPROACH:
    #   The old Layer 3 added "KbdBlock" to the UpperFilters registry value for
    #   the entire Keyboard device class {4D36E96B-...}.  "KbdBlock" is a
    #   non-existent driver  --  Windows cannot load it and marks every keyboard in
    #   the class with Code 39 (driver load failure), including external USB
    #   keyboards.  That is catastrophic for a user whose internal keyboard is
    #   already broken.
    #
    #   This scheduled task targets only the specific InstanceId that was
    #   selected, runs at startup as SYSTEM, and survives Windows Update.
    try {
        $iid     = $dev.InstanceId
        $psCmd   = "Disable-PnpDevice -InstanceId '$iid' -Confirm:`$false -ErrorAction SilentlyContinue"
        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                       -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -Command `"$psCmd`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $sett    = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
                       -MultipleInstances IgnoreNew -StartWhenAvailable
        $princ   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $script:TaskName -Action $action `
            -Trigger $trigger -Settings $sett -Principal $princ -Force -EA Stop | Out-Null
        $out.Add('[OK] Layer 3  --  Startup task created: keyboard stays disabled after reboots and Windows Update.')
        Write-Log "L3 Scheduled task registered for: $iid"
        $ok = $true
    } catch {
        $out.Add("[!!] Layer 3  --  Scheduled task creation failed: $_")
        Write-Log "L3 task fail: $_" 'WARN'
    }

    # -- Layer 4 - Group Policy Hardware-ID block (Pro/Enterprise/Education) ---
    # Prevents Windows from re-enabling the device via plug-and-play.
    # Uses the specific hardware ID of this device  --  no other device is affected.
    if ($script:IsPro) {
        try {
            $gp  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
            $gid = "$gp\DenyDeviceIDs"
            foreach ($p in @($gp, $gid)) {
                if (-not (Test-Path $p)) { New-Item $p -Force | Out-Null }
            }
            $hwId = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId `
                        -KeyName 'DEVPKEY_Device_HardwareIds' -EA SilentlyContinue).Data |
                    Select-Object -First 1
            if ($hwId) {
                # Find next free value name so we don't overwrite existing policy entries
                $existing = (Get-Item $gid -EA SilentlyContinue).Property
                $nextNum  = 1
                while ($existing -contains "$nextNum") { $nextNum++ }
                Set-ItemProperty $gid -Name "$nextNum"        -Value $hwId -Type String -Force
                Set-ItemProperty $gp  -Name 'DenyDeviceIDs'   -Value 1    -Type DWord  -Force
                Set-ItemProperty $gp  -Name 'DenyDeviceIDsRetroactive' -Value 1 -Type DWord -Force
                $out.Add("[OK] Layer 4  --  Windows policy HW-ID block applied: $hwId")
                Write-Log "L4 GPO block: $hwId (slot $nextNum)"
            } else {
                $out.Add('[--] Layer 4  --  Could not read hardware ID. Layers 1 - 3 still active.')
            }
        } catch {
            $out.Add("[!!] Layer 4  --  Policy write failed: $_")
            Write-Log "L4 GPO fail: $_" 'WARN'
        }
    } else {
        $out.Add('[--] Layer 4  --  Skipped (Windows Home). Layers 1 - 3 provide sufficient persistence.')
    }

    $msgs.Value = $out
    return $ok
}

# -----------------------------------------------------------------------------
#  REVERT  (undo all layers)
# -----------------------------------------------------------------------------
function Invoke-Revert($path) {
    $out = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path $path)) { return @("[!!] Backup not found: $path") }
    try {
        $b = Import-Clixml $path

        # Re-enable PnP device
        try {
            Enable-PnpDevice -InstanceId $b.InstanceId -Confirm:$false -EA Stop
            $out.Add('[OK] Device re-enabled in Device Manager.')
        } catch { $out.Add("[!!] PnP re-enable: $_") }

        # Restore i8042prt Start value
        if ($null -ne $b.RegI8042) {
            try {
                Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\i8042prt' `
                    -Name Start -Value $b.RegI8042 -Type DWord -Force
                $out.Add("[OK] PS/2 driver restored (Start=$($b.RegI8042)).")
            } catch { $out.Add("[!!] i8042prt restore: $_") }
        }

        # CRITICAL: remove the startup re-disable task  --  otherwise the keyboard
        # gets re-disabled again on the very next boot after the user reverts.
        try {
            Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -EA Stop
            $out.Add('[OK] Startup re-disable task removed.')
        } catch {
            if ($_ -match 'cannot find') { $out.Add('[--] No startup task found (already removed).') }
            else                         { $out.Add("[!!] Task removal: $_") }
        }

        # Remove Group Policy HW-ID block (remove entire DenyDeviceIDs key;
        # this is safe because we only ever add entries for this keyboard)
        try {
            $gid = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceIDs'
            if (Test-Path $gid) { Remove-Item $gid -Recurse -Force -EA SilentlyContinue }
            $gp  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
            if (Test-Path $gp) {
                Remove-ItemProperty $gp -Name 'DenyDeviceIDs'             -EA SilentlyContinue
                Remove-ItemProperty $gp -Name 'DenyDeviceIDsRetroactive'  -EA SilentlyContinue
            }
            $out.Add('[OK] Windows policy device block removed.')
        } catch { $out.Add("[!!] Policy block removal: $_") }

        $out.Add('')
        $out.Add('Revert complete. RESTART your PC to fully restore keyboard input.')
        Write-Log "Revert from $path complete."
    } catch {
        $out.Add("[!!] Revert error: $_")
        Write-Log "Revert error: $_" 'ERROR'
    }
    return $out
}

# -----------------------------------------------------------------------------
#  GUI
# -----------------------------------------------------------------------------
function Show-GUI {
    Get-OSInfo

    $C = @{
        bg0  = [System.Drawing.Color]::FromArgb(13,13,20)
        bg1  = [System.Drawing.Color]::FromArgb(22,22,34)
        bg2  = [System.Drawing.Color]::FromArgb(30,30,46)
        emrb = [System.Drawing.Color]::FromArgb(55,18,0)    # emergency panel background
        acc  = [System.Drawing.Color]::FromArgb(100,180,255)
        grn  = [System.Drawing.Color]::FromArgb(80,200,120)
        red  = [System.Drawing.Color]::FromArgb(200,60,60)
        pur  = [System.Drawing.Color]::FromArgb(180,140,255)
        gold = [System.Drawing.Color]::FromArgb(240,190,60)
        emr  = [System.Drawing.Color]::FromArgb(230,80,0)   # emergency button
        fg   = [System.Drawing.Color]::FromArgb(220,220,235)
        dim  = [System.Drawing.Color]::FromArgb(90,90,120)
    }

    # Monospace font with proper WinForms fallback (no CSS comma-list)
    $monoFace = if ([System.Drawing.FontFamily]::Families |
                     Where-Object { $_.Name -eq 'Cascadia Code' }) {
                    'Cascadia Code'
                } else { 'Consolas' }

    $F = @{
        ui   = New-Object System.Drawing.Font('Segoe UI', 9)
        hd   = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
        emr  = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
        ttl  = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
        mon  = New-Object System.Drawing.Font($monoFace, 8)
    }

    # -- Form -----------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'Keyboard Disabler v4.0'
    $form.Size            = New-Object System.Drawing.Size(780, 680)
    $form.StartPosition   = 'CenterScreen'
    $form.BackColor       = $C.bg0
    $form.ForeColor       = $C.fg
    $form.Font            = $F.ui
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox     = $false

    function Label($txt,$x,$y,$w,$h,$fnt,$fg,$bg=$null) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text=$txt; $l.Location=New-Object System.Drawing.Point($x,$y)
        $l.Size=New-Object System.Drawing.Size($w,$h); $l.Font=$fnt; $l.ForeColor=$fg
        if ($bg) { $l.BackColor=$bg }
        $form.Controls.Add($l); return $l
    }
    function Btn($txt,$x,$y,$w,$h,$bg,$fg,[System.Windows.Forms.Control]$parent=$form) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text=$txt; $b.Location=New-Object System.Drawing.Point($x,$y)
        $b.Size=New-Object System.Drawing.Size($w,$h)
        $b.BackColor=$bg; $b.ForeColor=$fg
        $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0
        $b.Font=$F.hd; $b.Cursor='Hand'
        $parent.Controls.Add($b); return $b
    }

    # -- Title bar -------------------------------------------------------------
    Label '  [KB]  Internal Keyboard Disabler' 0 0 780 46 $F.ttl $C.acc $C.bg1
    $osStr = "$($script:OSEdition -replace 'Microsoft Windows ','Win ')  *  Build $($script:OSBuild)  *  " +
             $(if($script:IsPro){'Pro/Ent  --  all 4 layers active'}else{'Home  --  3 layers active'})
    Label "  $osStr" 0 46 780 22 $F.ui $C.grn $C.bg2

    # -- Emergency recovery panel (always visible; fully mouse-operable) -------
    # This panel must stay visible and functional even after a disable operation
    # goes wrong and leaves the user with NO keyboard at all.
    $pnlEmr = New-Object System.Windows.Forms.Panel
    $pnlEmr.Location  = New-Object System.Drawing.Point(0, 68)
    $pnlEmr.Size      = New-Object System.Drawing.Size(780, 58)
    $pnlEmr.BackColor = $C.emrb
    $form.Controls.Add($pnlEmr)

    $lblEmr = New-Object System.Windows.Forms.Label
    $lblEmr.Text      = "  [!]  KEYBOARD NOT WORKING?`n  Click the button ->  it finds your backup automatically"
    $lblEmr.Location  = New-Object System.Drawing.Point(8, 4)
    $lblEmr.Size      = New-Object System.Drawing.Size(460, 50)
    $lblEmr.Font      = $F.hd
    $lblEmr.ForeColor = $C.gold
    $pnlEmr.Controls.Add($lblEmr)

    $btnEmrRecover = New-Object System.Windows.Forms.Button
    $btnEmrRecover.Text      = "[UNLOCK]  EMERGENCY RECOVER  (1-Click)"
    $btnEmrRecover.Location  = New-Object System.Drawing.Point(468, 9)
    $btnEmrRecover.Size      = New-Object System.Drawing.Size(300, 40)
    $btnEmrRecover.BackColor = $C.emr
    $btnEmrRecover.ForeColor = [System.Drawing.Color]::White
    $btnEmrRecover.FlatStyle = 'Flat'
    $btnEmrRecover.FlatAppearance.BorderSize = 0
    $btnEmrRecover.Font      = $F.emr
    $btnEmrRecover.Cursor    = 'Hand'
    $pnlEmr.Controls.Add($btnEmrRecover)

    # -- Step 1 ----------------------------------------------------------------
    Label 'STEP 1   --   Select the keyboard to disable' 16 138 700 20 $F.hd $C.pur

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(16,160)
    $lv.Size     = New-Object System.Drawing.Size(740,118)
    $lv.View     = 'Details'; $lv.FullRowSelect=$true; $lv.GridLines=$true
    $lv.BackColor=$C.bg1; $lv.ForeColor=$C.fg; $lv.BorderStyle='FixedSingle'
    $lv.Font     = $F.ui
    @('#',28),('Keyboard Name',264),('Status',70),('Likely Internal?',110),('Instance ID',238) |
        ForEach-Object { [void]$lv.Columns.Add($_[0],[int]$_[1]) }
    $form.Controls.Add($lv)

    $btnRefresh = Btn '[R]  Refresh List'             16 288 190 34 ([System.Drawing.Color]::FromArgb(20,50,110)) $C.acc
    $btnTest    = Btn '?  Help Identify Internal'   218 288 220 34 ([System.Drawing.Color]::FromArgb(20,70,40)) $C.grn

    # -- Step 2 ----------------------------------------------------------------
    Label 'STEP 2   --   Action' 16 336 700 20 $F.hd $C.pur

    $btnDisable = Btn '[X]  DISABLE Selected Keyboard  (permanent)' 16 360 360 42 $C.red ([System.Drawing.Color]::White)
    $btnRevert  = Btn '<-  Revert / Re-enable'                      390 360 220 42 ([System.Drawing.Color]::FromArgb(20,80,45)) $C.grn
    $btnLog     = Btn '[LOG]  Open Log'                                622 360 134 42 $C.bg2 $C.dim

    $btnDisable.Enabled = $false

    # -- Status box -----------------------------------------------------------
    Label 'STATUS' 16 416 80 16 $F.hd $C.pur
    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Location   = New-Object System.Drawing.Point(16,434)
    $rtb.Size       = New-Object System.Drawing.Size(740,196)
    $rtb.ReadOnly   = $true; $rtb.BackColor=$C.bg0; $rtb.ForeColor=$C.grn
    $rtb.Font       = $F.mon; $rtb.BorderStyle='None'; $rtb.ScrollBars='Vertical'
    $form.Controls.Add($rtb)

    # -- Footer ---------------------------------------------------------------
    Label '  Backup auto-saved before every disable   *   external USB keyboard is NOT affected by any layer' `
          0 640 780 32 $F.ui $C.dim $C.bg2

    # -- Inner helpers ---------------------------------------------------------
    function Log($msg,$color=$C.grn) {
        $rtb.SelectionStart=$rtb.TextLength; $rtb.SelectionLength=0
        $rtb.SelectionColor=$color; $rtb.AppendText("$msg`n")
        $rtb.ScrollToCaret()
    }

    function Update-EmergencyButton {
        $latest = Get-LatestBackup
        if ($latest) {
            $btnEmrRecover.Text = "[UNLOCK]  EMERGENCY RECOVER  (1-Click)`nBackup: $($latest.Name)"
        } else {
            $btnEmrRecover.Text = "[UNLOCK]  EMERGENCY RECOVER`n(no backup found yet)"
        }
    }

    function LoadKBs {
        $lv.Items.Clear()
        Log 'Scanning keyboards...' $C.acc
        $kbs = Get-AllKeyboards
        if (-not $kbs) { Log '[!] No keyboards found.' $C.red; return }
        $i = 1
        foreach ($k in $kbs) {
            $internal = Test-IsLikelyInternal $k
            $item = New-Object System.Windows.Forms.ListViewItem($i.ToString())
            [void]$item.SubItems.Add($k.FriendlyName)
            [void]$item.SubItems.Add($k.Status)
            [void]$item.SubItems.Add($(if($internal){'YES  *'}else{'no'}))
            [void]$item.SubItems.Add($k.InstanceId)
            $item.Tag = $k
            if ($internal) {
                $item.BackColor=[System.Drawing.Color]::FromArgb(50,18,18)
                $item.ForeColor=[System.Drawing.Color]::FromArgb(255,140,100)
            }
            [void]$lv.Items.Add($item); $i++
        }
        Log "Found $($kbs.Count) keyboard(s).  Orange rows = likely internal." $C.gold
        Log 'Click a row to select it, then click the red Disable button.' $C.fg
        Update-EmergencyButton
    }

    function DoRevert($backupPath) {
        Log "> Reverting from: $(Split-Path $backupPath -Leaf)..." $C.acc
        $rr = Invoke-Revert $backupPath
        foreach ($m in $rr) {
            $col = if     ($m -match '^\[OK\]') { $C.grn }
                   elseif ($m -match '^\[!!\]') { $C.red }
                   else                         { $C.dim }
            Log $m $col
        }
        LoadKBs
        [System.Windows.Forms.MessageBox]::Show(
            "Recovery complete!`n`nPlease RESTART your PC to fully restore your keyboard.",
            'Recovery Done  --  Restart Required',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }

    # -- Events ---------------------------------------------------------------

    # Emergency recover  --  one click, no keyboard needed
    $btnEmrRecover.Add_Click({
        $latest = Get-LatestBackup
        if (-not $latest) {
            [System.Windows.Forms.MessageBox]::Show(
                "No backup file was found in the TEMP folder.`n`n" +
                "If you have not yet run a Disable operation, your keyboard state has not been changed by this tool.`n`n" +
                "If you believe a backup exists elsewhere, use the 'Revert / Re-enable' button to browse for it.",
                'No Backup Found',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "EMERGENCY RECOVERY`n`n" +
            "This will restore your keyboard using the most recent backup:`n`n" +
            "  $($latest.Name)`n" +
            "  Created: $($latest.LastWriteTime)`n`n" +
            "Proceed? (You will need to restart your PC afterward.)",
            'Emergency Recovery',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ans -eq 'Yes') { DoRevert $latest.FullName }
    })

    $btnRefresh.Add_Click({ LoadKBs })

    $btnTest.Add_Click({
        [System.Windows.Forms.MessageBox]::Show(
            "HOW TO CONFIRM WHICH KEYBOARD IS INTERNAL`n`n" +
            "1. Unplug your external USB keyboard.`n" +
            "2. Try typing on the laptop's built-in keys.`n" +
            "3. Plug the external keyboard back in.`n" +
            "4. Click 'Refresh List'  --  the entry that STAYS is the internal one.`n`n" +
            "What to look for:`n" +
            "  - Rows highlighted in orange (marked YES  *)`n" +
            "  - Instance IDs starting with ACPI\\ or I2C\\`n" +
            "  - Names like 'Standard PS/2 Keyboard' or 'HID Keyboard Device'`n`n" +
            "Your external USB keyboard will say 'USB' in its Instance ID and will`n" +
            "DISAPPEAR from the list when you unplug it.",
            'Identify Internal Keyboard',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    })

    $lv.Add_SelectedIndexChanged({
        $btnDisable.Enabled = ($lv.SelectedItems.Count -gt 0)
    })

    $btnDisable.Add_Click({
        $sel = $lv.SelectedItems[0]
        $dev = $sel.Tag
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Permanently disable this keyboard?`n`n" +
            "  $($dev.FriendlyName)`n" +
            "  ID: $($dev.InstanceId)`n`n" +
            "What will happen:`n" +
            "  [+] A backup is saved first (used by Emergency Recover).`n" +
            "  [+] Your external USB keyboard will NOT be affected.`n" +
            "  [+] A startup task ensures it stays disabled after updates/reboots.`n`n" +
            "If anything goes wrong after restarting:`n" +
            "  -> Run this script again`n" +
            "  -> Click the orange EMERGENCY RECOVER button at the top`n`n" +
            "Continue?",
            'Confirm Disable',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($ans -ne 'Yes') { Log 'Cancelled.' $C.dim; return }

        Log ''; Log '> Saving backup...' $C.acc
        $bk = Save-Backup $dev
        Log "  Backup: $bk" $C.dim
        Update-EmergencyButton

        Log '> Applying disable layers...' $C.gold
        $r  = [ref]@()
        $ok = Disable-InternalKeyboard $dev $r
        foreach ($line in $r.Value) {
            $col = if     ($line -match '^\[OK\]') { $C.grn }
                   elseif ($line -match '^\[!!\]') { $C.red }
                   else                            { $C.dim }
            Log $line $col
        }

        Log ''
        if ($ok) {
            Log '>  ALL DONE.  Please restart your PC now.' $C.gold
            [System.Windows.Forms.MessageBox]::Show(
                "Internal keyboard disabled!`n`n" +
                "Please RESTART your PC to apply all layers.`n`n" +
                "If anything goes wrong after restarting, run this script again`n" +
                "and click the orange EMERGENCY RECOVER button.`n`n" +
                "Backup saved at:`n$bk",
                'Done  --  Restart Required',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } else {
            Log '>  One or more layers failed  --  see STATUS above.' $C.red
        }
        LoadKBs
    })

    $btnRevert.Add_Click({
        # Try to offer the latest backup as a one-click option first
        $latest = Get-LatestBackup
        if ($latest) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "Most recent backup found:`n`n" +
                "  $($latest.Name)`n" +
                "  Created: $($latest.LastWriteTime)`n`n" +
                "Use this backup to re-enable the keyboard?`n`n" +
                "(Click No to browse for a different backup file.)",
                'Select Backup',
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($ans -eq 'Cancel') { return }
            if ($ans -eq 'Yes')    { DoRevert $latest.FullName; return }
        }
        # Fallback: file picker
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title          = 'Select backup to revert from'
        $dlg.InitialDirectory = $env:TEMP
        $dlg.Filter         = 'Backup (KB_Backup*.xml)|KB_Backup*.xml|All XML|*.xml'
        if ($dlg.ShowDialog() -eq 'OK') { DoRevert $dlg.FileName }
    })

    $btnLog.Add_Click({
        if (Test-Path $script:LogFile) { Start-Process notepad $script:LogFile }
        else { Log 'No log file yet.' $C.dim }
    })

    # -- Startup ---------------------------------------------------------------
    Log "Keyboard Disabler v4.0   --   $(Get-Date -Format 'yyyy-MM-dd HH:mm')" $C.acc
    Log "OS: $($script:OSEdition)  Build $($script:OSBuild)" $C.dim
    Log $(if($script:IsPro) {
             'Edition: Pro/Enterprise  --  all 4 layers will be applied.'
          } else {
             'Edition: Home  --  Layers 1-3 active (PnP + i8042prt + startup task).'
          }) $C.grn
    $existingTask = Get-ScheduledTask -TaskName $script:TaskName -EA SilentlyContinue
    if ($existingTask) {
        Log "  Note: Re-disable startup task is already registered." $C.gold
    }
    Log ''

    # Auto-scan keyboards so the user doesn't have to remember to click Refresh
    LoadKBs

    [void]$form.ShowDialog()
}

Write-Log "Started. User=$env:USERNAME Machine=$env:COMPUTERNAME"
Show-GUI
Write-Log 'Exited.'
