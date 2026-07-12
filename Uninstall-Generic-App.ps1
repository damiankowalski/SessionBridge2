### Path script
$path = $MyInvocation.MyCommand.Path
if (!$path -and $psISE) {$path = $psISE.CurrentFile.FullPath}
if ($path) {$path = Split-Path $path -Parent}
Set-Location $path
$sourcepath = "$path\SRC"

### Variables
$LogApp  = "${Env:programdata}\Microsoft\IntuneManagementExtension\Logs"
$msiexec = "${Env:Windir}\system32\msiexec.exe"

# ---- CONFIG: set what you're targeting ----
$ApplicationName    = "*visual studio code*"   # wildcard match against DisplayName - use carefully
$ApplicationTag     = "visual studio code"       # used only for log file naming, no spaces/slashes

# How long (seconds) to wait for a per-user uninstall launched via scheduled task
# before giving up polling. The task itself is not force-killed after this - we just
# stop waiting and move on to the next app. Increase for slow uninstallers.
#
# IMPORTANT - SCCM vs Intune: Invoke-RunAsCurrentUser launches a process in the signed-in
# user's session from a SYSTEM-context script. Microsoft's own docs explicitly call this
# category of technique (comparable to serviceui.exe) unsupported for Intune Win32 apps:
# "Techniques that attempt to force interaction with the signed-in user session ... are
# not supported and may result in inconsistent or unpredictable behavior."
# This script is written for SCCM (always runs as the SCCM SYSTEM account) - if it's ever
# repurposed for Intune deployment, this entire per-user dispatch mechanism needs to be
# dropped in favor of a fully silent approach.
$RunAsUserTimeoutSeconds = 120

# How long (seconds) the process-close warning window waits before auto-closing the
# matched processes if the user doesn't click the button first.
$ProcessCloseTimeoutSeconds = 300

# Manual override for EXE apps that have NO QuietUninstallString in the registry.
# Leave both blank to keep skipping such apps (the safe default). Only fill these in
# once you've manually verified (e.g. via appwiz.cpl, vendor docs, or testing the
# switch yourself) that it produces a real silent, unattended uninstall for THIS
# specific app - this is a deliberate, informed override, not a guess made by the script.
$ManualSilentArguments   = ""            # e.g. "/S" or "/VERYSILENT /SUPPRESSMSGBOXES"
$ManualAcceptedExitCodes = @(0, 3010)    # exit codes to treat as success for that override

### Functions

function RunMSI ($FilePath, $ArgumentList, [int[]]$AcceptedExitCodes = @(0, 1605, 3010)) {
    $run = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -Wait
    $run.WaitForExit()
    Write-Verbose "Process finished with Exit Code: $($run.ExitCode)" -Verbose
    if ($AcceptedExitCodes -notcontains $run.ExitCode) {
        Write-Host "Process: `"$FilePath $ArgumentList`" has encountered error code:" $run.ExitCode
        [System.Environment]::Exit($run.ExitCode)
    }
}

function RunEXE ($FilePath, $ArgumentList, [int[]]$AcceptedExitCodes = @(0, 1605, 3010)) {
    # Start-Process's -ArgumentList has ValidateNotNullOrEmpty built in, so it must
    # only be passed when there's actually something to pass.
    $startParams = @{
        FilePath = $FilePath
        PassThru = $true
        Wait     = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($ArgumentList)) {
        $startParams.ArgumentList = $ArgumentList
    }

    $run = Start-Process @startParams
    $run.WaitForExit()
    Write-Verbose "Process finished with Exit Code: $($run.ExitCode)" -Verbose
    if ($AcceptedExitCodes -notcontains $run.ExitCode) {
        Write-Host "Process: `"$FilePath $ArgumentList`" has encountered error code:" $run.ExitCode
        [System.Environment]::Exit($run.ExitCode)
    }
}

# Returns real logged-on user SIDs whose hives are currently loaded under HKEY_USERS.
# Excludes system/service SIDs (S-1-5-18/19/20), .DEFAULT, and _Classes subkeys.
function Get-LoggedOnUserHives {
    Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' } |
        Select-Object -ExpandProperty PSChildName
}

function Get-InstalledApplication {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [String]$DisplayName,

        [Parameter(Mandatory = $false)]
        [String]$ProductCode,

        [Parameter(Mandatory = $false)]
        [String]$DisplayVersion
    )

    if (-not $ProductCode -and -not $DisplayName -and -not $DisplayVersion) {
        Write-Host "Error: Specify at least one of ProductCode, DisplayName, or DisplayVersion."
        return $false
    }

    $registryPaths = @(
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";              Bitness = "64-bit" }
        @{ Path = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"; Bitness = "32-bit" }
    )

    # Add per-user hives for any currently logged-on user (real HKEY_USERS enumeration -
    # HKCU inside a SYSTEM-context script would only ever show SYSTEM's own profile).
    foreach ($sid in (Get-LoggedOnUserHives)) {
        $registryPaths += @{ Path = "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";              Bitness = "64-bit (user: $sid)" }
        $registryPaths += @{ Path = "Registry::HKEY_USERS\$sid\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"; Bitness = "32-bit (user: $sid)" }
    }

    $foundApps = @()

    foreach ($regEntry in $registryPaths) {
        if (-not (Test-Path $regEntry.Path)) { continue }

        $installedApps = Get-ChildItem -Path $regEntry.Path -ErrorAction SilentlyContinue | ForEach-Object {
            try { Get-ItemProperty -Path $_.PSPath -ErrorAction Stop } catch { $null }
        }

        foreach ($app in $installedApps) {
            if (-not $app.DisplayName) { continue }  # skip noise entries with no name

            if ($ProductCode    -and $app.PSChildName    -ne $ProductCode)      { continue }
            if ($DisplayName    -and $app.DisplayName    -notlike $DisplayName) { continue }
            if ($DisplayVersion -and $app.DisplayVersion -ne $DisplayVersion)   { continue }

            $uninstallString = $app.UninstallString
            $isMsi = $false
            if ($uninstallString -match 'msiexec\.exe') { $isMsi = $true }

            $productCodeGuid = $null
            if ($isMsi) {
                if ($app.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
                    $productCodeGuid = $app.PSChildName
                } elseif ($uninstallString -match '(\{[0-9A-Fa-f-]{36}\})') {
                    $productCodeGuid = $matches[1]
                }
            }

            $foundApps += [PSCustomObject]@{
                DisplayName          = $app.DisplayName
                DisplayVersion       = $app.DisplayVersion
                Publisher            = $app.Publisher
                PSChildName          = $app.PSChildName
                RegistryPath         = $regEntry.Path
                Bitness              = $regEntry.Bitness
                IsPerUser            = $regEntry.Bitness -like "*user:*"
                InstallLocation      = $app.InstallLocation
                UninstallString      = $uninstallString
                QuietUninstallString = $app.QuietUninstallString
                UninstallType        = if ($isMsi) { "MSI" } else { "EXE" }
                ProductCode          = $productCodeGuid
            }
        }
    }

    if ($foundApps.Count -gt 0) {
        Write-Verbose "Found $($foundApps.Count) matching application(s)." -Verbose
        return $foundApps
    } else {
        Write-Verbose "No matching applications found." -Verbose
        return $false
    }
}

# Detects processes running under this app's own InstallLocation(s), and - only if any
# are found - shows a WPF countdown warning to the user, letting them close now or wait
# for the timeout, then force-closes them.
#
# ARCHITECTURE NOTE: detection and termination both run HERE, as SYSTEM - this is
# deliberate, not an oversight:
#   - Detection must stay with SYSTEM so it's reliable regardless of where the app is
#     installed (%USERPROFILE%, Program Files, anywhere) - SYSTEM's process visibility
#     is always complete.
#   - Termination must stay with SYSTEM so it works even if the app happens to be
#     running elevated (e.g. user launched it "as administrator") - a normal user
#     token can hit Access Denied trying to close a higher-integrity process, even one
#     that's technically "their own".
# ONLY the window itself is bridged into the user's session via SessionBridge.exe,
# because a WPF window drawn by a SYSTEM/Session-0 process is never visible to the
# user - that's the one and only piece of this that needs the interactive desktop.
# SessionBridge.exe stays SYSTEM-owned throughout; it just draws its bridged child's
# window on the user's desktop (WTSQueryUserToken + CreateProcessAsUser pattern, same
# approach as Microsoft's own ServiceUI.exe).
function Stop-ApplicationProcessWithWindow {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$InstallLocation,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 300,
        [Parameter(Mandatory = $false)]
        [string]$WindowTitle = "Action Required for Running Applications",
        [Parameter(Mandatory = $false)]
        [string]$HeaderText = "Applications Running",
        [Parameter(Mandatory = $false)]
        [string]$SubHeaderText = "Software deployment"
    )

    # Multiple registry entries can point to the same product installed in different
    # locations (e.g. VS Code's machine-wide AND per-user installers both present) - the
    # vendor's own uninstaller often checks "is this app running anywhere", not just under
    # the specific entry being removed, so we need to close all of them together up front.
    $normalizedPaths = @(
        $InstallLocation |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.TrimEnd('\') } |
            Where-Object { Test-Path $_ } |
            Select-Object -Unique
    )

    if ($normalizedPaths.Count -eq 0) {
        Write-Verbose "No valid InstallLocation(s) registered for $DisplayName - skipping pre-uninstall process check." -Verbose
        return
    }

    $escapedPaths = $normalizedPaths | ForEach-Object { [regex]::Escape($_) }

    # ---- STEP 1: DETECTION (as SYSTEM) ----
    $runningProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        if (-not $_.Path) { return $false }
        foreach ($escaped in $escapedPaths) {
            try { if ($_.Path -match "^$escaped\\") { return $true } } catch { }
        }
        return $false
    })

    if ($runningProcesses.Count -eq 0) {
        Write-Verbose "No running processes found under any of: $($normalizedPaths -join '; ') for $DisplayName." -Verbose
        return
    }

    Write-Verbose "Found $($runningProcesses.Count) running process(es) under: $($normalizedPaths -join '; ') for $DisplayName - showing close warning." -Verbose
    $runningProcesses | ForEach-Object { Write-Verbose "Will close: $($_.ProcessName) (PID $($_.Id)) - $($_.Path)" -Verbose }

    # ---- STEP 2: SHOW WINDOW (bridged into the user's session - display only) ----
    $sessionBridgeExe   = "$sourcepath\SessionBridge.exe"
    $closeWarningScript = "$sourcepath\Show-ProcessCloseWarning.ps1"

    $tempArgsDir = "${Env:programdata}\GlobalDesktop\Temp"
    if (-not (Test-Path $tempArgsDir)) { New-Item -Path $tempArgsDir -ItemType Directory -Force | Out-Null }
    $tempArgsFile = Join-Path $tempArgsDir "$((New-Guid).ToString('N')).json"

    # Only pass display data (name + path for icon lookup) - no PIDs, no process
    # objects. The bridged window script never touches the processes themselves.
    $appsToShow = $runningProcesses | Where-Object { $_.Path } | Group-Object Path | ForEach-Object {
        $proc = $_.Group[0]
        $name = $proc.Description
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $proc.Name }
        [PSCustomObject]@{ Name = $name; Path = $proc.Path }
    }

    $bridgeArgs = @{
        DisplayName    = $DisplayName
        TimeoutSeconds = $TimeoutSeconds
        WindowTitle    = $WindowTitle
        HeaderText     = $HeaderText
        SubHeaderText  = $SubHeaderText
        AppsToShow     = $appsToShow
    }
    $bridgeArgs | ConvertTo-Json -Depth 5 | Set-Content -Path $tempArgsFile -Encoding UTF8

    Write-Verbose "Invoking process-close window via SessionBridge for $DisplayName." -Verbose

    try {
        $bridgeProcess = Start-Process -FilePath $sessionBridgeExe `
            -ArgumentList "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$closeWarningScript`" -ArgsFile `"$tempArgsFile`"" `
            -PassThru -Wait -NoNewWindow

        Write-Verbose "SessionBridge (window step) returned exit code: $($bridgeProcess.ExitCode)" -Verbose
        if ($bridgeProcess.ExitCode -ne 0) {
            Write-Host "WARNING: process-close window did not complete cleanly (exit code $($bridgeProcess.ExitCode)) for $DisplayName - proceeding to close matched processes regardless."
        }
    }
    catch {
        Write-Host "WARNING: Failed to invoke SessionBridge for $DisplayName window step: $($_.Exception.Message) - proceeding to close matched processes regardless."
    }
    finally {
        Remove-Item -Path $tempArgsFile -Force -ErrorAction SilentlyContinue
    }

    # ---- STEP 3: TERMINATION (back on SYSTEM - re-detect fresh rather than reusing
    # stale PIDs from Step 1, in case anything changed during the wait) ----
    $freshRunningProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        if (-not $_.Path) { return $false }
        foreach ($escaped in $escapedPaths) {
            try { if ($_.Path -match "^$escaped\\") { return $true } } catch { }
        }
        return $false
    })

    if ($freshRunningProcesses.Count -gt 0) {
        Write-Verbose "Closing $($freshRunningProcesses.Count) process(es) for $DisplayName as SYSTEM (works regardless of process integrity level)." -Verbose
        $freshRunningProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# Some uninstallers (notably Inno Setup, used by VS Code's per-user installer) self-relaunch:
# the original process copies itself to %TEMP%, launches that copy, and exits almost
# immediately - while the real removal (including the registry key) finishes moments later
# in that detached process. A single immediate Test-Path can catch this in-between state,
# so poll for a short window instead of trusting one snapshot.
function Wait-ForRegistryRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string]$KeyName,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 60,
        [Parameter(Mandatory = $false)][int]$PollIntervalSeconds = 3
    )
    $fullPath = "$RegistryPath\$KeyName"
    $elapsed = 0
    while ((Test-Path $fullPath) -and $elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
        if ($elapsed % 15 -eq 0) {
            Write-Verbose "Still waiting for registry removal of '$fullPath' - ${elapsed}s elapsed of ${TimeoutSeconds}s." -Verbose
        }
    }

    if (Test-Path $fullPath) {
        # The vendor uninstaller's own cleanup didn't finish removing its Uninstall key
        # within the wait window. SYSTEM has full access to any loaded HKEY_USERS hive, so
        # rather than leaving a stale Add/Remove Programs entry behind indefinitely, remove
        # it directly - by this point the actual uninstall executable has already run and
        # done its real work (files/shortcuts), this is just cleaning up its leftover
        # registration that its own process never got back around to removing.
        Write-Verbose "Timeout reached - attempting direct removal of leftover registry key '$fullPath'." -Verbose
        try {
            Remove-Item -Path $fullPath -Recurse -Force -ErrorAction Stop
            Write-Verbose "Directly removed leftover registry key '$fullPath'." -Verbose
        } catch {
            Write-Verbose "Direct removal of '$fullPath' failed: $($_.Exception.Message)" -Verbose
        }
    }

    return -not (Test-Path $fullPath)
}

# Splits a raw QuietUninstallString/UninstallString (one string, path+args) into FilePath / Arguments
function Split-CommandLine {
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $CommandLine = $CommandLine.Trim()

    if ($CommandLine.StartsWith('"')) {
        $endQuote = $CommandLine.IndexOf('"', 1)
        if ($endQuote -gt 0) {
            $filePath  = $CommandLine.Substring(1, $endQuote - 1)
            $arguments = $CommandLine.Substring($endQuote + 1).Trim()
        } else {
            $filePath  = $CommandLine.Trim('"')
            $arguments = ""
        }
    } else {
        $splitIndex = $CommandLine.IndexOf(' ')
        if ($splitIndex -gt 0) {
            $filePath  = $CommandLine.Substring(0, $splitIndex)
            $arguments = $CommandLine.Substring($splitIndex + 1).Trim()
        } else {
            $filePath  = $CommandLine
            $arguments = ""
        }
    }

    return [PSCustomObject]@{ FilePath = $filePath; Arguments = $arguments }
}

<#
Invoke-RunAsCurrentUser
Launches a command in the active interactive user's session via a temporary scheduled task.
Needed because a SYSTEM-context process (SCCM/Intune) cannot directly execute per-user
uninstall commands in that user's context.
NOTE: this does not return an exit code - it polls task state up to -SleepDuration and
then moves on regardless. Treat per-user uninstalls as best-effort/fire-and-forget.
#>
function Invoke-RunAsCurrentUser {
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ExeAndArgs')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'ExeAndArgs')]
        [string]$Executable,
        [Parameter(Mandatory = $false, Position = 1, ParameterSetName = 'ExeAndArgs')]
        [AllowEmptyString()]
        [string]$ArgumentString,
        [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true, ParameterSetName = 'Parts')]
        [AllowEmptyString()]
        [string[]]$CommandToRunParts,
        [Parameter(Mandatory = $false)]
        [int]$SleepDuration = 30,
        [Parameter(Mandatory = $false)]
        [int]$PostExecutionGraceSeconds = 25
    )
    $TaskNamePrefix = "RunAsUser_"
    Write-Verbose "Searching for active interactive sessions..." -Verbose
    $ExplorerProcess = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" |
        Sort-Object CreationDate -Descending |
        Select-Object -First 1
    if (-not $ExplorerProcess) {
        Write-Host "Error: No active user session found (explorer.exe is not running)."
        return
    }
    $Owner = Invoke-CimMethod -InputObject $ExplorerProcess -MethodName "GetOwner"
    if (-not $Owner.User) {
        Write-Host "Error: Could not retrieve the owner of the explorer process."
        return
    }
    $TargetUser = if ($Owner.Domain) { "$($Owner.Domain)\$($Owner.User)" } else { $Owner.User }
    Write-Verbose "Target User detected: $TargetUser" -Verbose

    if ($PSCmdlet.ParameterSetName -eq 'Parts') {
        $Executable = $CommandToRunParts[0]
        $ArgumentString = if ($CommandToRunParts.Count -gt 1) {
            ($CommandToRunParts | Select-Object -Skip 1 | ForEach-Object {
                if ($_ -eq '') { '""' }
                elseif ($_ -match '\s' -and $_ -notmatch '^".*"$') {
                    '"' + ($_ -replace '"','\"') + '"'
                }
                else { $_ }
            }) -join ' '
        } else {
            $null
        }
    }
    # NOTE: Execute is a discrete Task Scheduler field, not a raw command line - it must
    # be the bare path with no surrounding quotes, or the task will fail to resolve the
    # file (and fail silently, since we don't see that error surfaced here).
    if ($Executable -match '^".*"$') {
        $Executable = $Executable.Trim('"')
    }
    Write-Verbose "Action: Executing '$Executable' with arguments '$($ArgumentString)'" -Verbose
    $TaskName = "$TaskNamePrefix$((New-Guid).ToString('N').Substring(0,8))"

    # Some installers (notably Inno Setup, used by VS Code's per-user installer) self-
    # relaunch: they copy themselves to %TEMP%, launch that copy, and the ORIGINAL process
    # (the one Task Scheduler is actually tracking) exits almost immediately - while the
    # real cleanup (including removing their own Uninstall registry key) finishes moments
    # later in that detached copy. Task Scheduler assigns the launched process to a Job
    # object and tears down that Job once the tracked process exits - which can kill the
    # detached copy before it finishes, even though it's still doing real work. Wrapping
    # the call through cmd.exe with a trailing 'timeout' keeps the TRACKED process alive
    # for a grace period regardless of how quickly its own direct child returns, without
    # changing what's actually being executed (same Executable/ArgumentString as always).
    $quotedExecutable = "`"$Executable`""
    $innerCommand = if ([string]::IsNullOrWhiteSpace($ArgumentString)) { $quotedExecutable } else { "$quotedExecutable $ArgumentString" }
    $cmdArgument = "/c $innerCommand & timeout /t $PostExecutionGraceSeconds /nobreak > nul"

    $ActionParams = @{
        Execute  = "$Env:WINDIR\System32\cmd.exe"
        Argument = $cmdArgument
    }
    $Action = New-ScheduledTaskAction @ActionParams
    $Principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Highest
    $Settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 4
    try {
        if ($PSCmdlet.ShouldProcess("Task: $TaskName", "Register and Start as $TargetUser")) {
            Register-ScheduledTask -TaskName $TaskName -Action $Action -Principal $Principal -Settings $Settings -Force -ErrorAction Stop
            Write-Verbose "Task '$TaskName' registered successfully." -Verbose
            Start-ScheduledTask -TaskName $TaskName
            Write-Verbose "Process launch initiated in user session." -Verbose

            # Start-ScheduledTask is asynchronous - the task can still report 'Ready'
            # for a brief window before actually transitioning to 'Running'. Without this,
            # a fast check here can fall straight through and unregister the task before
            # the process has reliably launched at all.
            $neverRunResult = 267011  # 0x41303 - "The task has not yet run"
            $startDeadline = (Get-Date).AddSeconds(10)
            do {
                Start-Sleep -Milliseconds 250
                $currentState = (Get-ScheduledTask -TaskName $TaskName).State
                $currentInfo  = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
            } while ($currentState -eq 'Ready' -and $currentInfo.LastTaskResult -eq $neverRunResult -and (Get-Date) -lt $startDeadline)
            Write-Verbose "Task state after start attempt: $currentState" -Verbose

            $StartWait = Get-Date
            while ((Get-ScheduledTask -TaskName $TaskName).State -eq 'Running' -and (New-TimeSpan -Start $StartWait -End (Get-Date)).TotalSeconds -lt $SleepDuration) {
                Start-Sleep -Milliseconds 500
            }

            $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($taskInfo) {
                Write-Verbose "Scheduled task '$TaskName' LastTaskResult: $($taskInfo.LastTaskResult) (0 = success)" -Verbose
                if ($taskInfo.LastTaskResult -ne 0) {
                    Write-Host "WARNING: run-as-user task for '$Executable' returned non-zero result: $($taskInfo.LastTaskResult)"
                }
            }
        }
    }
    catch {
        Write-Host "Critical Error: $($_.Exception.Message)"
    }
    finally {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Verbose "Cleanup: Temporary task '$TaskName' removed." -Verbose
        }
    }
}

### START Transcript
Start-Transcript "$LogApp\${ApplicationTag}_uninstall_wrapper.log" -Force

### START Detection + Removal
$foundApps = Get-InstalledApplication -DisplayName $ApplicationName

if ($foundApps) {

    # Phase 1: close processes for ALL matched entries together, before touching any of
    # them. Vendor uninstallers often check "is this app running anywhere", not just under
    # the specific entry being removed - if we started removal per-entry and only checked
    # that entry's own InstallLocation, a still-running instance from a DIFFERENT matched
    # entry (e.g. the per-user install while we're removing the machine-wide one) can cause
    # the vendor's own uninstaller to pop its own "please close the app" dialog on us.
    $allInstallLocations = @($foundApps | Select-Object -ExpandProperty InstallLocation)
    Write-Verbose "Closing any running processes across all $($foundApps.Count) matched application entr$(if ($foundApps.Count -eq 1) {'y'} else {'ies'}) before removing any of them." -Verbose
    Stop-ApplicationProcessWithWindow -InstallLocation $allInstallLocations -DisplayName $ApplicationName -TimeoutSeconds $ProcessCloseTimeoutSeconds

    # Phase 2: remove each matched entry.
    foreach ($app in $foundApps) {

        Write-Verbose "Processing: $($app.DisplayName) [$($app.DisplayVersion)] ($($app.Bitness), $($app.UninstallType))" -Verbose

        $logSafeName = ($app.DisplayName -replace '[\\/:*?"<>|]', '_')
        $execPath = $null
        $execArgs = $null
        $execAcceptedExitCodes = @(0, 1605, 3010)

        if ($app.UninstallType -eq "MSI") {

            if (-not $app.ProductCode) {
                Write-Host "Could not resolve a ProductCode GUID for $($app.DisplayName). Skipping."
                continue
            }

            $execPath = $msiexec
            $execArgs = "/x $($app.ProductCode) /qb-! REBOOT=`"ReallySuppress`" /l*v `"$LogApp\${ApplicationTag}_${logSafeName}_$($app.DisplayVersion)_uninstall.log`""

        } else {

            if ($app.QuietUninstallString) {
                $parsed = Split-CommandLine -CommandLine $app.QuietUninstallString

                # Inno Setup uninstallers (named unins0XX.exe by convention) can hang
                # indefinitely on an unattended message box if /SILENT is used without
                # /SUPPRESSMSGBOXES - there's nobody present to click it in an automated
                # context, so the process never reaches its final step (removing its own
                # registry key). This is a documented, official Inno Setup switch for
                # exactly this situation - not an override of the vendor's own string, just
                # adding the one switch needed to make it behave unattended as intended.
                # Confirmed via real-world reports of this exact VS Code failure even
                # through Intune's own official "Install behavior: User" mechanism.
                if ($parsed.FilePath -match '(?i)unins\d+\.exe$' -and $parsed.Arguments -notmatch '(?i)/SUPPRESSMSGBOXES') {
                    Write-Verbose "Inno Setup uninstaller detected for $($app.DisplayName) without /SUPPRESSMSGBOXES - appending it to prevent hanging on an unattended message box." -Verbose
                    $parsed.Arguments = "$($parsed.Arguments) /SUPPRESSMSGBOXES".Trim()
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($ManualSilentArguments)) {
                # No QuietUninstallString - only proceed because you've manually confirmed
                # (outside this script) that this switch produces a real silent uninstall
                # for THIS specific app, and supplied it yourself via $ManualSilentArguments.
                Write-Host "No QuietUninstallString for $($app.DisplayName) - using manually supplied silent arguments: '$ManualSilentArguments'"
                Write-Verbose "Manual override in use for $($app.DisplayName): arguments='$ManualSilentArguments' acceptedExitCodes=$($ManualAcceptedExitCodes -join ',')" -Verbose
                $parsed = Split-CommandLine -CommandLine $app.UninstallString
                $parsed.Arguments = "$($parsed.Arguments) $ManualSilentArguments".Trim()
                $execAcceptedExitCodes = $ManualAcceptedExitCodes
            } else {
                Write-Host "SKIPPED - no QuietUninstallString and no manual silent arguments supplied for $($app.DisplayName) [$($app.DisplayVersion)] ($($app.Bitness))."
                Write-Verbose "SKIPPED (no QuietUninstallString, no manual override): $($app.DisplayName) [$($app.DisplayVersion)] $($app.Bitness)" -Verbose
                continue
            }

            if (-not (Test-Path $parsed.FilePath)) {
                Write-Host "Uninstaller executable not found at path: $($parsed.FilePath). Skipping $($app.DisplayName)."
                continue
            }

            $execPath = $parsed.FilePath
            $execArgs = $parsed.Arguments
        }

        if ($app.IsPerUser) {
            # The uninstall COMMAND itself still needs to run as that user, since a per-user
            # registered app's un-registration is tied to that user's profile - this is a
            # functional requirement, unrelated to the (invisible) process-close window above.
            Write-Verbose "Per-user install detected for $($app.DisplayName) - dispatching uninstall in the current interactive user's session." -Verbose
            Invoke-RunAsCurrentUser -Executable $execPath -ArgumentString $execArgs -SleepDuration $RunAsUserTimeoutSeconds
        } else {
            if ($app.UninstallType -eq "MSI") {
                RunMSI $execPath $execArgs -AcceptedExitCodes $execAcceptedExitCodes
            } else {
                RunEXE $execPath $execArgs -AcceptedExitCodes $execAcceptedExitCodes
            }
        }

        # Per-user removals go through a scheduled task with no reliable exit code, and
        # some installers (Inno Setup) finish asynchronously after the tracked process
        # exits - so poll for actual removal rather than checking once immediately.
        $removalTimeout = if ($app.IsPerUser) { 90 } else { 20 }
        $removed = Wait-ForRegistryRemoval -RegistryPath $app.RegistryPath -KeyName $app.PSChildName -TimeoutSeconds $removalTimeout
        if ($removed) {
            Write-Verbose "Confirmed: registry entry for $($app.DisplayName) is gone." -Verbose
        } else {
            Write-Host "WARNING: registry entry for $($app.DisplayName) still present after uninstall attempt - verify manually."
        }
    }

} else {
    Write-Verbose "$ApplicationName is not installed on this PC." -Verbose
    [System.Environment]::Exit(0)
}

Stop-Transcript
