### Path script
$path = $MyInvocation.MyCommand.Path
if (!$path) {$path = $psISE.CurrentFile.Fullpath}
if ( $path) {$path = Split-Path $path -Parent}
Set-Location $path
$sourcepath = "$path\SRC"

### Variables
$LogApp = "${Env:programdata}\Microsoft\IntuneManagementExtension\Logs"
$ApplicationName = "VisualStudioCode"
$ApplicationVersion = "1.127.0"
$InstallDir = "${env:ProgramFiles}\Microsoft VS Code"

### Functions

function RunEXE ($FilePath, $ArgumentList) {
    Write-Host "Running command: $FilePath $ArgumentList"
    $Run = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -Wait
    $Run.WaitForExit()
    if (($Run.ExitCode -ne 0) -and ($Run.ExitCode -ne 3010)) {
        Write-Host "Process: `"$FilePath $ArgumentList`" has encountered error code:" $Run.ExitCode
        [System.Environment]::Exit($Run.ExitCode)
    }
    else {
        Write-Host "Process finished successfully with Exit Code: $($Run.ExitCode)"
    }
}

function Remove-Folder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IfEmpty
    )
    
    if (Test-Path -Path $Path) {
        if (-not $IfEmpty) {
            Write-Host "Removing folder: $Path"
            Remove-Item -Path $Path -Recurse -Force
        }
        else {
            if ((Get-ChildItem $Path | Measure-Object).Count -eq 0) {
                Write-Host "Removing empty folder: $Path"
                Remove-Item -Path $Path -Force
            }
        }
    }
}

function Format-Json {
    <#
    .DESCRIPTION
        Reformats a JSON string so the output looks better than what ConvertTo-Json outputs.
    .PARAMETER Json
        Required: [string] The JSON text to prettify.
    .EXAMPLE
        $json | ConvertTo-Json | Format-Json
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string]$Json
    )

    $Indentation = 4
    $indent = 0
    $regexUnlessQuoted = '(?=([^"]*"[^"]*")*[^"]*$)'

    $result = $Json -split '\r?\n' |
        ForEach-Object {
            # If the line contains a ] or } character, 
            # we need to decrement the indentation level unless it is inside quotes.
            if ($_ -match "[}\]]$regexUnlessQuoted") {
                $indent = [Math]::Max($indent - $Indentation, 0)
            }

            # Replace all colon-space combinations by ": " unless it is inside quotes.
            $line = (' ' * $indent) + ($_.TrimStart() -replace ":\s+$regexUnlessQuoted", ': ')

            # If the line contains a [ or { character, 
            # we need to increment the indentation level unless it is inside quotes.
            if ($_ -match "[\{\[]$regexUnlessQuoted") {
                $indent += $Indentation
            }

            $line
        }

    return $result -Join [Environment]::NewLine
}

<#
Invoke-PreInstallCleanup

OPTIONAL pre-installation step. Call this BEFORE installing the new version if you
want any existing installation(s) of the application removed first (e.g. upgrading
from an unknown/older prior version, or migrating from a per-user install to a
machine-wide one). Skip calling it entirely for a fresh-install-only package.

What it does, in order:
  1. Detects any installed version(s) of the app on this machine via the registry -
     both the machine-wide HKLM Uninstall keys AND every currently logged-on user's
     own HKEY_USERS hive (so per-user installs are found too, not just HKLM ones).
  2. If any matched installation has running processes, shows a WPF warning window
     to the logged-in user via SessionBridge.exe (bridged into their interactive
     session - a window drawn by this SYSTEM-context script would otherwise be
     invisible, since Intune/SCCM runs this as SYSTEM in Session 0). The user can
     close the running app themselves, or the countdown will force-close it. Process
     detection and termination both stay with THIS SYSTEM-context function, never
     with the bridged window process - only the window itself is bridged. This
     matters even for a Program Files install: it makes sure the process is closed
     even if it happens to be running elevated, which a bridged user-session process
     might not have rights to do.
  3. Fully uninstalls every matched registry entry (MSI via msiexec, EXE via its
     QuietUninstallString, or dispatched to the user's session via a scheduled task
     for HKEY_USERS-registered per-user installs), then confirms the registry entry
     is actually gone before returning.

This function's job ends here - it does not install anything. Installation of the
new version remains entirely the responsibility of the rest of this script, after
this function returns.

All helper functions below (Get-InstalledApplication, RunMSI, RunEXE, etc.) are
DELIBERATELY nested inside this function rather than defined at script scope. This
keeps them fully local to this function's own scope, so they cannot collide with or
silently override any same-named function this template already defines for its own
use elsewhere (e.g. this template's own top-level RunEXE above, which has a simpler
signature - no -AcceptedExitCodes support, and does not tolerate an empty
-ArgumentList the way the nested RunEXE below does). You can drop this function into
any install template as-is, regardless of what helper function names that template
already uses.
#>
function Invoke-PreInstallCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApplicationNameFilter,

        [Parameter(Mandatory = $false)]
        [int]$ProcessCloseTimeoutSeconds = 300,

        [Parameter(Mandatory = $false)]
        [int]$RunAsUserTimeoutSeconds = 120
    )

    # ---- Nested helper functions (local to this function only) ----

    function RunMSI ($FilePath, $ArgumentList, [int[]]$AcceptedExitCodes = @(0, 1605, 3010)) {
        $Run = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -Wait
        $Run.WaitForExit()
        Write-Verbose "Process finished with Exit Code: $($Run.ExitCode)" -Verbose
        if ($AcceptedExitCodes -notcontains $Run.ExitCode) {
            Write-Host "Process: `"$FilePath $ArgumentList`" has encountered error code:" $Run.ExitCode
            [System.Environment]::Exit($Run.ExitCode)
        }
    }

    function RunEXE ($FilePath, $ArgumentList, [int[]]$AcceptedExitCodes = @(0, 1605, 3010)) {
        # -ArgumentList has ValidateNotNullOrEmpty built in, so it must only be
        # passed when there's actually something to pass.
        $startParams = @{
            FilePath = $FilePath
            PassThru = $true
            Wait     = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($ArgumentList)) {
            $startParams.ArgumentList = $ArgumentList
        }

        $Run = Start-Process @startParams
        $Run.WaitForExit()
        Write-Verbose "Process finished with Exit Code: $($Run.ExitCode)" -Verbose
        if ($AcceptedExitCodes -notcontains $Run.ExitCode) {
            Write-Host "Process: `"$FilePath $ArgumentList`" has encountered error code:" $Run.ExitCode
            [System.Environment]::Exit($Run.ExitCode)
        }
    }

    # Returns real logged-on user SIDs whose hives are currently loaded under
    # HKEY_USERS. Excludes system/service SIDs, .DEFAULT, and _Classes subkeys.
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
                if (-not $app.DisplayName) { continue }

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

    # Detects running processes under the app's InstallLocation(s) as SYSTEM, and -
    # only if any are found - bridges a display-only warning window into the user's
    # session via SessionBridge.exe, then closes the processes back as SYSTEM once
    # the window returns (click or timeout). Detection and termination deliberately
    # stay with SYSTEM (this function); only the window itself is bridged.
    function Stop-ApplicationProcessWithWindow {
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string[]]$InstallLocation,
            [Parameter(Mandatory = $true)]
            [string]$DisplayName,
            [Parameter(Mandatory = $false)]
            [int]$TimeoutSeconds = 300
        )

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

        Write-Verbose "Found $($runningProcesses.Count) running process(es) for $DisplayName - showing close warning." -Verbose

        # The bridged process runs with the LOGGED-IN USER's own (limited) token - it
        # needs actual read access to whatever data file we ask it to open (the JSON
        # args). $sourcepath sits inside Intune's IMECache content folder, which is
        # deliberately SYSTEM/Administrators-only (that's the content protection
        # .intunewin gives us) - a standard user token cannot read anything there.
        # SessionBridge.exe itself does NOT need copying: it's launched by THIS
        # SYSTEM-context script (SYSTEM reads it fine from IMECache) and is already
        # running as SYSTEM by the time it internally calls CreateProcessAsUser - the
        # user's token only ever needs to read the files handed to the BRIDGED child
        # process (the JSON args here), never SessionBridge.exe's own file.
        #
        # This folder does not need an explicit ACL grant: C:\ProgramData's default
        # permissions already include BUILTIN\Users: Read & Execute, and a subfolder
        # created here without breaking inheritance picks that up automatically. (If
        # your org's GPO hardens ProgramData's default ACL, re-add an explicit grant
        # here.)
        $bridgeWorkDir = "$Env:ProgramData\ApplicationServices\${ApplicationName}_${ApplicationVersion}"
        if (-not (Test-Path $bridgeWorkDir)) {
            New-Item -Path $bridgeWorkDir -ItemType Directory -Force | Out-Null
        }

        $sessionBridgeExe   = "$sourcepath\SessionBridge.exe"
        $closeWarningScript = Join-Path $bridgeWorkDir "Show-ProcessCloseWarning.ps1"
        Copy-Item -Path "$sourcepath\Show-ProcessCloseWarning.ps1" -Destination $closeWarningScript -Force

        $tempArgsFile = Join-Path $bridgeWorkDir "$((New-Guid).ToString('N')).json"

        $appsToShow = $runningProcesses | Where-Object { $_.Path } | Group-Object Path | ForEach-Object {
            $proc = $_.Group[0]
            $name = $proc.Description
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $proc.Name }
            [PSCustomObject]@{ Name = $name; Path = $proc.Path }
        }

        $bridgeArgs = @{
            DisplayName    = $DisplayName
            TimeoutSeconds = $TimeoutSeconds
            AppsToShow     = $appsToShow
        }
        $bridgeArgs | ConvertTo-Json -Depth 5 | Set-Content -Path $tempArgsFile -Encoding UTF8

        try {
            $bridgeProcess = Start-Process -FilePath $sessionBridgeExe `
                -ArgumentList "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$closeWarningScript`" -ArgsFile `"$tempArgsFile`"" `
                -PassThru -Wait -NoNewWindow

            if ($bridgeProcess.ExitCode -ne 0) {
                Write-Host "WARNING: process-close window did not complete cleanly (exit code $($bridgeProcess.ExitCode)) for $DisplayName - proceeding to close matched processes regardless."
            }
        }
        catch {
            Write-Host "WARNING: Failed to invoke SessionBridge for $DisplayName window step: $($_.Exception.Message) - proceeding to close matched processes regardless."
        }
        finally {
            # Whole scratch folder, not just the two files - nothing else needs it
            # once this one bridging step is done.
            Remove-Item -Path $bridgeWorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        $freshRunningProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            if (-not $_.Path) { return $false }
            foreach ($escaped in $escapedPaths) {
                try { if ($_.Path -match "^$escaped\\") { return $true } } catch { }
            }
            return $false
        })

        if ($freshRunningProcesses.Count -gt 0) {
            Write-Verbose "Closing $($freshRunningProcesses.Count) process(es) for $DisplayName as SYSTEM." -Verbose
            $freshRunningProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

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

    function Invoke-RunAsCurrentUser {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param(
            [Parameter(Mandatory = $true)]
            [string]$Executable,
            [Parameter(Mandatory = $false)]
            [AllowEmptyString()]
            [string]$ArgumentString,
            [Parameter(Mandatory = $false)]
            [int]$SleepDuration = 30,
            [Parameter(Mandatory = $false)]
            [int]$PostExecutionGraceSeconds = 25
        )
        $TaskNamePrefix = "RunAsUser_"
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

        if ($Executable -match '^".*"$') {
            $Executable = $Executable.Trim('"')
        }
        $TaskName = "$TaskNamePrefix$((New-Guid).ToString('N').Substring(0,8))"

        # Run the uninstaller through a hidden PowerShell host rather than cmd.exe.
        # cmd.exe has no reliable "hidden" mode of its own when launched this way via
        # a Task Scheduler action - it visibly flashes/hangs on screen for the user,
        # which is what we're fixing here. -WindowStyle Hidden is a genuine startup
        # switch PowerShell honors for its own console window, so this is actually
        # invisible, not just minimized.
        #
        # Start-Sleep replaces the old "cmd.exe ... & timeout ..." trick for the same
        # purpose: some uninstallers (notably Inno Setup, used by VS Code's per-user
        # installer) self-relaunch - the tracked process exits almost immediately
        # while the real cleanup finishes moments later in a detached copy. Keeping
        # this hidden host alive for a grace period after -Wait returns gives that
        # detached copy time to finish before Task Scheduler tears down the Job
        # object tied to this task.
        $escapedExecutable = $Executable.Replace("'", "''")
        $escapedArgumentString = if ($ArgumentString) { $ArgumentString.Replace("'", "''") } else { "" }

        $innerScript = if ([string]::IsNullOrWhiteSpace($escapedArgumentString)) {
            "Start-Process -FilePath '$escapedExecutable' -WindowStyle Hidden -Wait"
        } else {
            "Start-Process -FilePath '$escapedExecutable' -ArgumentList '$escapedArgumentString' -WindowStyle Hidden -Wait"
        }
        $innerScript += "; Start-Sleep -Seconds $PostExecutionGraceSeconds"

        $ActionParams = @{
            Execute  = "$Env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
            Argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$innerScript`""
        }
        $Action = New-ScheduledTaskAction @ActionParams
        $Principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Highest
        $Settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 4
        try {
            if ($PSCmdlet.ShouldProcess("Task: $TaskName", "Register and Start as $TargetUser")) {
                Register-ScheduledTask -TaskName $TaskName -Action $Action -Principal $Principal -Settings $Settings -Force -ErrorAction Stop
                Start-ScheduledTask -TaskName $TaskName

                $neverRunResult = 267011
                $startDeadline = (Get-Date).AddSeconds(10)
                do {
                    Start-Sleep -Milliseconds 250
                    $currentState = (Get-ScheduledTask -TaskName $TaskName).State
                    $currentInfo  = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
                } while ($currentState -eq 'Ready' -and $currentInfo.LastTaskResult -eq $neverRunResult -and (Get-Date) -lt $startDeadline)

                $StartWait = Get-Date
                while ((Get-ScheduledTask -TaskName $TaskName).State -eq 'Running' -and (New-TimeSpan -Start $StartWait -End (Get-Date)).TotalSeconds -lt $SleepDuration) {
                    Start-Sleep -Milliseconds 500
                }

                $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
                if ($taskInfo -and $taskInfo.LastTaskResult -ne 0) {
                    Write-Host "WARNING: run-as-user task for '$Executable' returned non-zero result: $($taskInfo.LastTaskResult)"
                }
            }
        }
        catch {
            Write-Host "Critical Error: $($_.Exception.Message)"
        }
        finally {
            if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            }
        }
    }

    # ---- Function body: detect, warn+close, remove ----

    $foundApps = Get-InstalledApplication -DisplayName $ApplicationNameFilter

    if (-not $foundApps) {
        Write-Verbose "$ApplicationNameFilter is not installed on this PC - nothing to remove before install." -Verbose
        return
    }

    $allInstallLocations = @($foundApps | Select-Object -ExpandProperty InstallLocation)
    Write-Verbose "Pre-install cleanup: closing any running processes across all $($foundApps.Count) matched application entr$(if ($foundApps.Count -eq 1) {'y'} else {'ies'}) before removing any of them." -Verbose
    Stop-ApplicationProcessWithWindow -InstallLocation $allInstallLocations -DisplayName $ApplicationNameFilter -TimeoutSeconds $ProcessCloseTimeoutSeconds

    foreach ($app in $foundApps) {

        Write-Verbose "Pre-install cleanup: removing $($app.DisplayName) [$($app.DisplayVersion)] ($($app.Bitness), $($app.UninstallType))" -Verbose

        $execPath = $null
        $execArgs = $null
        $execAcceptedExitCodes = @(0, 1605, 3010)

        if ($app.UninstallType -eq "MSI") {
            if (-not $app.ProductCode) {
                Write-Host "Could not resolve a ProductCode GUID for $($app.DisplayName). Skipping."
                continue
            }
            $logSafeName = ($app.DisplayName -replace '[\\/:*?"<>|]', '_')
            $execPath = "${Env:Windir}\system32\msiexec.exe"
            $execArgs = "/x $($app.ProductCode) /qb-! REBOOT=`"ReallySuppress`" /l*v `"$LogApp\PreInstallCleanup_${logSafeName}_$($app.DisplayVersion)_uninstall.log`""
        }
        else {
            if ($app.QuietUninstallString) {
                $parsed = Split-CommandLine -CommandLine $app.QuietUninstallString

                if ($parsed.FilePath -match '(?i)unins\d+\.exe$' -and $parsed.Arguments -notmatch '(?i)/SUPPRESSMSGBOXES') {
                    $parsed.Arguments = "$($parsed.Arguments) /SUPPRESSMSGBOXES".Trim()
                }
            } else {
                Write-Host "SKIPPED - no QuietUninstallString for $($app.DisplayName) [$($app.DisplayVersion)] ($($app.Bitness)) - add a manual override here if needed."
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
            Invoke-RunAsCurrentUser -Executable $execPath -ArgumentString $execArgs -SleepDuration $RunAsUserTimeoutSeconds
        } else {
            if ($app.UninstallType -eq "MSI") {
                RunMSI $execPath $execArgs -AcceptedExitCodes $execAcceptedExitCodes
            } else {
                RunEXE $execPath $execArgs -AcceptedExitCodes $execAcceptedExitCodes
            }
        }

        Write-Verbose "Pre-install cleanup: uninstall command for $($app.DisplayName) completed." -Verbose
    }
}

### START Transcript
Start-Transcript "$LogApp\${ApplicationName}_${ApplicationVersion}_install_wrapper.log"

### START Pre-Installation
# OPTIONAL: uncomment the line below to remove any existing installed version(s) of
# this app (found via registry, HKLM + all logged-on users' HKEY_USERS hives) before
# installing the new version - including warning the user and closing running
# processes via SessionBridge if needed. Leave commented out for a fresh-install-only
# package where this isn't needed.
# Invoke-PreInstallCleanup -ApplicationNameFilter "*Visual Studio Code*"

Write-Verbose "Closing application processes" -Verbose
Get-Process | Where-Object { $_.Path -like "$InstallDir\*" -or $_.Name -eq "Code" } | Stop-Process -PassThru -Force
Write-Verbose "All processes closed" -Verbose

# Cleanup previous Active Setup configuration
$ActiveSetupEntries = @("Visual Studio Code_1.67.2", "Visual Studio Code_1.71.2", "Visual Studio Code_1.105.1")
$ActiveSetupKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components"
foreach ($Entry in $ActiveSetupEntries) {
    if (Test-Path "$ActiveSetupKey\$Entry") {
        Write-Host "Removing registry: $ActiveSetupKey\$Entry"
        Remove-Item -Path "$ActiveSetupKey\$Entry" -Recurse -Force
    }
}

Remove-Folder "$InstallDir\userconf"

### START Installation
Write-Verbose "Start installation" -Verbose
RunEXE "$sourcepath\VSCodeSetup-x64-1.127.0.exe" "/SP- /VERYSILENT /SUPPRESSMSGBOXES /NOCANCEL /NORESTART /FORCECLOSEAPPLICATIONS /MERGETASKS=!runcode /log `"$LogApp\${ApplicationName}_${ApplicationVersion}_install.log`""

# Disable updates and set config for users
Write-Verbose "Configuration..." -Verbose

$Users = Get-ChildItem -Directory "$Env:SystemDrive\Users" -Force -Exclude "All Users", "Public", "Default User"
foreach ($User in $Users) {
    $Destination = "$User\AppData\Roaming\Code\User"
    $ConfigFile = "settings.json"

    if (Test-Path -Path "$Destination\$ConfigFile") {
        $FileContent = Get-Content "$Destination\$ConfigFile" | ConvertFrom-Json
        $Settings = @{"update.showReleaseNotes" = $false; "update.enableWindowsBackgroundUpdates" = $false;
                      "extensions.autoCheckUpdates" = $false; "update.mode" = "manual"
        }

        foreach ($Key in $Settings.Keys) {
            if (!$FileContent.PSObject.Properties.Name.Contains($Key)) { 
                $FileContent | Add-Member -MemberType NoteProperty -Name $Key -Value $Settings[$Key]
            }
            else {
                $FileContent."$Key" = $Settings[$Key]
            }
        }

        $FileContent | ConvertTo-Json -Depth 32 | Format-Json | Set-Content "$Destination\$ConfigFile" -Force
        Write-Host "Modified file: $Destination\$ConfigFile"
    }
    else {
        if (!(Test-Path -Path $Destination)) { New-Item -Path $Destination -Type Directory -Force | Out-Null }
        Copy-Item -Path "$SourcePath\Config\$ConfigFile" -Destination $Destination -Force
        Write-Host "$ConfigFile copied to $Destination"
    }
}

Write-Verbose "Installation finished successfully" -Verbose

### END Installation
Stop-Transcript
