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

<#
Invoke-ProcessCloseWarning

OPTIONAL step, call this BEFORE removing the application's files if you want the
user warned (and given a chance to save their work) when the app is currently
running, instead of silently force-closing it with no notice.

Unlike Invoke-PreInstallCleanup (the install.ps1 equivalent), this function does NOT
search the registry for anything and does NOT uninstall anything itself - this
script already knows exactly which app it's removing and how (that's the rest of
this uninstall.ps1, below). This function's only job is:
  1. Detect (as SYSTEM) whether any process is currently running under the given
     -InstallLocation.
  2. If so, bridge a display-only WPF warning window into the user's session via
     SessionBridge.exe (a window drawn directly by this SYSTEM/Session-0 script
     would otherwise be invisible to the user) - showing the process list, and
     either the user clicks "Close & Continue" or a countdown auto-closes them.
  3. Close the matched process(es) back as SYSTEM once the window returns (works
     reliably regardless of install path or process integrity level - a bridged
     user-session process can't always close an elevated process, SYSTEM always
     can).

Detection and termination both happen HERE, as SYSTEM - never inside the bridged
window script - by design, for the same reasons as the install-side function.
#>
function Invoke-ProcessCloseWarning {
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
        Write-Verbose "No valid InstallLocation(s) provided for $DisplayName - skipping process check." -Verbose
        return
    }

    $escapedPaths = $normalizedPaths | ForEach-Object { [regex]::Escape($_) }

    # ---- Detection (as SYSTEM) ----
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

    Write-Verbose "Found $($runningProcesses.Count) running process(es) for $DisplayName - showing close warning before uninstall." -Verbose

    # ---- Show window (bridged into the user's session - display only) ----
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
        HeaderText     = "Applications Running"
        SubHeaderText  = "This application is about to be removed"
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
        # Whole scratch folder, not just the two files - nothing else needs it once
        # this one bridging step is done.
        Remove-Item -Path $bridgeWorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---- Termination (back on SYSTEM - re-detect fresh rather than trusting stale
    # PIDs from before the wait) ----
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

### START Transcript
Start-Transcript "$LogApp\${ApplicationName}_${ApplicationVersion}_uninstall_wrapper.log"

### START Uninstallation

# OPTIONAL: uncomment to warn the user (and give them a chance to save work) if the
# app is currently running, before it gets force-closed below. Leave commented out
# to keep the previous silent-close behavior with no user notice.
# Invoke-ProcessCloseWarning -InstallLocation $InstallDir -DisplayName "Visual Studio Code"

Write-Verbose "Closing application processes" -Verbose
Get-Process | Where-Object { $_.Path -like "$InstallDir\*" -or $_.Name -eq "Code" } | Stop-Process -PassThru -Force
Write-Verbose "All processes closed" -Verbose

Write-Verbose "Start uninstallation" -Verbose

$Uninstaller = "$InstallDir\unins000.exe"
if (Test-Path -Path $Uninstaller) {
    RunEXE $Uninstaller "/VERYSILENT /NORESTART /log `"$LogApp\${ApplicationName}_${ApplicationVersion}_uninstall.log`""

    Write-Verbose "Removing folders" -Verbose
    Remove-Folder -Path "$Env:SystemDrive\Users\Default\AppData\Roaming\Code\User"
    Remove-Folder -Path "$Env:SystemDrive\Users\Default\AppData\Roaming\Code" -IfEmpty
}
else {
    Write-Verbose "File: $Uninstaller does not exist, uninstallation is not possible." -Verbose
    [System.Environment]::Exit(1)
}

Write-Verbose "Uninstallation finished successfully" -Verbose

### END Installation
Stop-Transcript
