# SessionBridge

A minimal .NET Framework 4.8 console utility that bridges a single interactive
window from a SYSTEM-context process into the logged-in user's session. Built
to solve the "Session 0 isolation" problem for Intune/SCCM Win32 app deployments:
software deployed this way runs as SYSTEM in a non-interactive session, so any
UI it tries to show directly is invisible to the user.

This is the same problem Microsoft's own `ServiceUI.exe` (MDT/MDOP toolkit)
solves, using the same underlying technique (`WTSQueryUserToken` +
`DuplicateTokenEx` + `CreateProcessAsUser`) - SessionBridge is a minimal,
purpose-built equivalent for our packaging standard.

## Where this fits in the bigger picture

SessionBridge is **not** a general-purpose "run my script as the user" tool,
and it is **not** meant to carry business logic. Our packaging templates -
`install.ps1` and `uninstall.ps1` - run as SYSTEM start to finish: registry
detection across `HKLM`/`HKEY_USERS`, transcript logging, MSI/EXE
install/uninstall, everything. SessionBridge is invoked from *inside* those
scripts for exactly one narrow step: showing a WPF "close running
applications" warning window to the user. Everything before and after that
one step stays SYSTEM.

Each template exposes this as an **optional** function the packager can call
if/when it's needed for that specific app:

- **`install.ps1` → `Invoke-PreInstallCleanup`** - the full picture: detects
  any existing installation(s) of the app via the registry (`HKLM` +
  every logged-on user's `HKEY_USERS` hive), warns and closes running
  processes if needed, then fully uninstalls every matched entry before the
  new version installs.
- **`uninstall.ps1` → `Invoke-ProcessCloseWarning`** - a lighter version:
  this script already knows exactly what it's removing and how, so this
  function only handles the "warn the user, close running processes"
  step - no registry search, no uninstall logic.

```
SYSTEM (whole script): detect running processes matching InstallLocation(s)
  → nothing found? skip straight to install/uninstall
  → found? SYSTEM bridges ONLY the window into the user's session:
        SessionBridge.exe → Show-ProcessCloseWarning.ps1 (display only,
        no process detection or termination logic inside it)
    SYSTEM: once the window closes (click or timeout), SYSTEM re-detects
            and force-closes the matching processes itself
SYSTEM (whole script): proceed with install/uninstall as normal
```

Detection and termination both stay with SYSTEM deliberately:
- **Detection** needs to work regardless of where the app is installed
  (`%USERPROFILE%`, `Program Files`, anywhere) - SYSTEM's process visibility
  is always complete; a session-bridged user token's isn't guaranteed to be.
- **Termination** needs to work even if the matched process happens to be
  running elevated (e.g. the user launched it "as administrator") - a normal
  user token can hit Access Denied trying to close a higher-integrity
  process, even one that's technically "theirs." SYSTEM can always close it.

Both functions' helper functions (`RunMSI`, `RunEXE`, `Get-InstalledApplication`,
etc.) are deliberately **nested inside** the outer function rather than
defined at script scope. This keeps them local to that function only, so
dropping this into any packaging template - regardless of what helper
function names that template already uses for its own install/uninstall
logic - can't silently collide with or override anything already there.

## What SessionBridge.exe does

1. Enumerates all sessions on the machine (`WTSEnumerateSessions`), filters to
   the `Active` one(s).
2. Obtains that session's logged-in user token (`WTSQueryUserToken` +
   `DuplicateTokenEx`, `SecurityIdentification` level, `TokenPrimary` type).
3. Loads that user's environment block, so the bridged process resolves paths
   exactly as if the user had launched it themselves.
4. Launches the command line it's given into that session's interactive
   desktop (`CreateProcessAsUser`, `winsta0\default`), with an explicit,
   universally-readable working directory (`C:\Windows\Temp`) rather than
   inheriting the caller's own - see "File accessibility," below, for why
   this matters.
5. **Waits** for that process to exit and returns its exit code as its own -
   this makes SessionBridge usable for "show something, wait for the
   outcome, then continue" flows, not just fire-and-forget.

SessionBridge itself carries zero domain knowledge - it doesn't know or care
what it's launching. The specific script name/path it's told to run lives
entirely in the calling PowerShell script, not in the exe. Renaming or
swapping the bridged script requires no changes to SessionBridge.exe at all.

## File accessibility for the bridged process

This is a real gotcha worth understanding if you're extending either
template: **the bridged process runs with the logged-in user's own, limited
token - it needs actual read access to whatever file you point it at.**

When packages are deployed via Intune, the package contents get extracted
into Intune's per-app content-cache folder (`C:\Windows\IMECache\...`) -
which is deliberately SYSTEM/Administrators-only, to protect cached package
content from tampering. A standard user's token has **no access there at
all**. Pointing the bridged script directly at a path under that folder
fails with `ERROR_ACCESS_DENIED (5)` - not a bug in the bridging logic
itself, just a straightforward permissions mismatch.

Both `Invoke-PreInstallCleanup` and `Invoke-ProcessCloseWarning` handle this
the same way: before invoking SessionBridge, SYSTEM (which has full access
to the IMECache folder) copies just the two files the bridged process
actually needs - `Show-ProcessCloseWarning.ps1` and a small JSON file with
the display data - into a scratch folder under
`C:\ProgramData\ApplicationServices\<AppName>_<AppVersion>\`. This inherits
`C:\ProgramData`'s default permissions (`BUILTIN\Users: Read & Execute`) with
no extra ACL work needed, and the whole folder is deleted again once the
window step completes - nothing persists.

**`SessionBridge.exe` itself is never copied and needs no such handling** -
it's launched directly by the SYSTEM-context script (which already has full
access to IMECache) and is already running as SYSTEM by the time it
internally calls `CreateProcessAsUser`. The user's token only ever needs to
read the files handed to the *bridged child process* it creates - never
SessionBridge.exe's own file.

## What it explicitly does NOT do

- It does not grant the launched process any new privileges - it runs with
  the **logged-in user's own token**, same rights as if they'd launched it
  themselves.
- It does not accept dynamic/remote/user-supplied input - the command line is
  supplied only by the calling SYSTEM-context script, with a fixed, reviewed
  payload. It is not intended to be called with arbitrary or
  externally-influenced input.
- It does not detect or terminate any processes itself - see above, that
  logic deliberately stays with the SYSTEM-context caller.
- It does not persist, install a service, or run continuously.

## Build

- Visual Studio 2022, .NET Framework 4.8, Console App template.
- Recommended: Release config, `x64` platform target.
- See [project-properties.md](project-properties.md) for the full rundown of
  which project settings matter here and why.

## Usage

```
SessionBridge.exe <full command line to run in the user's session>
```

Called only from inside a SYSTEM-context packaging script - never invoked
directly by Intune/SCCM itself, and never with a payload built from anything
other than a fixed, reviewed path.

## Distribution

Packages using this pattern are shipped as `.intunewin` archives. See
[SECURITY.md](SECURITY.md) for what that means for the trust model - in
short, it's a net positive (encrypted transport, integrity-checked, scoped to
assigned devices/users), but it does not replace code-signing the exe itself.

## Logging

- File log: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\SessionBridge.log`
- Event Log: Application log, source `SessionBridge`

Both are best-effort and non-fatal - a logging failure never blocks or
crashes the actual bridged launch.

## Security review notes

See [SECURITY.md](SECURITY.md).

## Versioning

Tagged releases (`vX.Y.Z`), see [CHANGELOG.md](CHANGELOG.md).

## License

Internal use only - [org name / license terms].
