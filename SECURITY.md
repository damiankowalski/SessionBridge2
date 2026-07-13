# Security Review Notes — SessionBridge

## Purpose of this document

SessionBridge duplicates a logged-in user's access token and launches a
process into their interactive session, from a process running as SYSTEM.
This is structurally similar to a technique used in some token-manipulation
attacks, so it warrants explicit review. This document gives security
reviewers and Enterprise Architecture what they need to assess it in one
place, and reflects the current (final) design as of this revision.

## Scope: what SessionBridge is used for in practice

SessionBridge is invoked from *inside* SYSTEM-context packaging scripts, for
exactly one purpose: showing a WPF "applications are running, close them or
wait" warning window to the logged-in user. It is not used to relocate any
business logic (registry work, process detection, process termination,
package install/removal) into the user's session - all of that stays with
the SYSTEM-context caller, before and after the one bridged step.

Two entry points exist in the packaging templates, both optional and both
following the same scoping rule:
- **`install.ps1` → `Invoke-PreInstallCleanup`** - detects existing
  installation(s) via the registry, bridges the warning window if processes
  are running, then removes each matched entry - all as SYSTEM except the
  window itself.
- **`uninstall.ps1` → `Invoke-ProcessCloseWarning`** - a narrower version:
  no registry search (the uninstall script already knows its target), just
  detect → bridge the window → terminate, all as SYSTEM except the window.

This scoping matters for review: the blast radius of SessionBridge itself is
"can display a window and wait for it to close," not "can execute arbitrary
per-app logic as the user."

## Threat model

**What this tool can do:**
- Launch a specific, caller-supplied command line into the active user's
  interactive session, using the user's own (not elevated) token, and wait
  for it to exit.

**What this tool cannot do:**
- It cannot elevate the launched process beyond the logged-in user's own
  rights. `DuplicateTokenEx` is called with `SecurityIdentification`, not
  `SecurityImpersonation` or `SecurityDelegation` - the resulting token
  carries the user's own privilege set, nothing more.
- It does not read, modify, or exfiltrate the user's token or credentials;
  the token handle is used only to call `CreateProcessAsUser` and is closed
  immediately after use.
- It does not accept input from the network, registry, or any
  externally-writable location - only from its own command-line arguments,
  which in practice are always built by the calling SYSTEM script from a
  fixed, reviewed path.
- It does not itself perform process detection or termination - by design,
  those stay with the SYSTEM-context caller (see Scope, above), specifically
  so that detection/termination work reliably regardless of install
  location or process integrity level, which a bridged user-session process
  cannot guarantee.
- It does not rely on an implicit or inherited working directory:
  `lpCurrentDirectory` is explicitly set to a fixed, universally-readable
  path (`C:\Windows\Temp`) rather than passed as `NULL` (which would inherit
  the calling process's own working directory - see "File staging and
  IMECache," below, for why that was a real problem in practice, not just a
  theoretical one).

**Primary risk to mitigate:** if this binary is ever invoked with an
attacker-controlled command line, it would launch that payload into the
user's session. Mitigation: **the binary must only be invoked by our own
packaging scripts, with a hardcoded, reviewed command line** - never with a
payload path derived from user input, network sources, or unvalidated
config. This is enforced by convention in the calling script, not by the
exe itself, since the exe is intentionally generic.

## File staging and IMECache - a resolved design issue worth documenting

Early production testing surfaced `CreateProcessAsUser` failing with
`ERROR_ACCESS_DENIED (5)` when deployed via Intune (this had not appeared in
local/manual testing). Root cause: the bridged script was being pointed
directly at a path under Intune's per-app content-cache folder
(`C:\Windows\IMECache\...`), which is deliberately SYSTEM/Administrators-only
- protecting cached package content from tampering by standard users. The
bridged process runs with the logged-in user's own (limited) token, which
has no access there at all.

This is now handled explicitly, and is worth noting for reviewers as a
positive control rather than a residual risk: before invoking SessionBridge,
the calling SYSTEM-context script copies only the two files the bridged
process needs (the window script and a small JSON file of display data - app
names and icon paths, nothing sensitive) into a scratch folder at
`C:\ProgramData\ApplicationServices\<AppName>_<AppVersion>\`. This folder:
- inherits `C:\ProgramData`'s default ACL (`BUILTIN\Users: Read & Execute`) -
  no explicit permission grant is made or needed;
- is created fresh per invocation and **deleted in its entirety** once the
  window step completes, regardless of success or failure (wrapped in a
  `finally` block) - nothing persists between runs;
- never contains `SessionBridge.exe` itself, which does not need copying:
  it's launched directly by the SYSTEM-context script (full access to
  IMECache) and is already running as SYSTEM by the time it internally calls
  `CreateProcessAsUser` - only the *bridged child process* it creates needs
  file access, never SessionBridge.exe's own binary.

## An explicitly rejected alternative design

An earlier draft of this tool used `OpenProcessToken` on SessionBridge's own
(SYSTEM) token, duplicated it, and used `SetTokenInformation` with
`TokenSessionId` to relocate that SYSTEM token's session ID, then launched
the payload with that modified **SYSTEM** token - requiring `SeTcbPrivilege`
("Act as part of the operating system"). This was reviewed and **rejected**:
it results in the bridged process running with full SYSTEM rights (not the
user's rights) merely rendered onto the user's desktop, requires one of the
most sensitive privileges in Windows, and is a documented token-manipulation
pattern associated with session-hijacking/privilege-escalation techniques -
not the pattern used by `ServiceUI.exe`, despite surface-level similarity.
The shipped implementation uses `WTSQueryUserToken` (the user's own token),
not this rejected approach, and does not request or use `SeTcbPrivilege`
anywhere.

## Comparison to precedent

This tool exists to solve the same "Session 0 isolation" problem as
Microsoft's own `ServiceUI.exe`, shipped as part of the MDT/MDOP toolkit and
already in wide enterprise use for exactly this SCCM/Intune scenario. The
approach (enumerate sessions → duplicate the user's own token →
CreateProcessAsUser onto `winsta0\default`) is the documented pattern for
this problem, not a novel technique.

## Required privileges

The process must run as SYSTEM (or another account holding
`SeAssignPrimaryTokenPrivilege` and `SeIncreaseQuotaPrivilege`). Both
privileges are explicitly enabled at startup via `AdjustTokenPrivileges`
before any token duplication occurs - see `EnablePrivilege()` in
`Program.cs`. `SeTcbPrivilege` is neither requested nor required.

## Distribution: `.intunewin` packaging

Packages using this pattern are distributed as `.intunewin` archives via
Intune. This is a net positive for the trust model, with one caveat:

**Positives:**
- Content is AES-256 encrypted by the Win32 Content Prep Tool before upload,
  and only decrypted locally by the Intune Management Extension (IME) agent
  on the target device - the exe is never exposed in plaintext in transit or
  in cloud storage.
- The `.intunewin` manifest includes content hashes; a tampered archive fails
  integrity checks rather than silently running modified content.
- Delivery is scoped to devices/users explicitly assigned the app in Intune -
  this reinforces (at the platform level) the constraint that this tool is
  only ever invoked as part of an authorized deployment, not run ad hoc.

**Caveat - does not replace code signing:** encryption protects the
distribution channel, not the artifact itself. Once IME decrypts and writes
`SessionBridge.exe` to disk on the endpoint, local AV/EDR evaluates it like
any other file on disk. Code signing (see below) remains a required control,
not an optional one, regardless of the `.intunewin` wrapper.

**Trust boundary shift:** because delivery goes through Intune, the
practical trust boundary for "who can cause this exe to run, with what
payload" becomes **RBAC over who can publish/modify Win32 app assignments in
the Intune tenant** - this should be an explicit access-control review item
alongside the code-level review of this repository.

## Code signing

- [ ] Signed with [org] internal code-signing certificate before deployment
      (applied via `signtool.exe` post-build, or a build-event/CI step - this
      is separate from the Visual Studio "Signing" tab, which governs
      strong-name signing, not Authenticode signing)
- [ ] Signing certificate chain verified by security team
- [ ] Binary hash recorded per release (see CHANGELOG.md)

## Logging / auditability

Every session enumerated, every token operation, and every launch attempt
(success or failure, with Win32 error code) is logged to:
- File: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\SessionBridge.log`
- Windows Event Log: Application log, source `SessionBridge`

## Deployment constraints (for reviewers)

- Deployed only via `.intunewin` packages assigned through Intune, with a
  fixed, reviewed command-line payload built by the calling packaging
  script - never accepts payload paths from user input, network sources, or
  unvalidated config.
- The bridged script and its JSON parameters are always staged into a
  standard-user-readable scratch folder under
  `C:\ProgramData\ApplicationServices\<AppName>_<AppVersion>\` before
  SessionBridge is invoked - never pointed directly at Intune's IMECache
  content-cache folder, which is SYSTEM/Administrators-only by design.
- Platform target: x64 only, Windows 10/11 and Windows Server, matching our
  supported endpoint fleet.
- RBAC over Intune Win32 app publishing/assignment is the practical access
  control for "who can cause this to run and with what" (see Distribution,
  above).

## Open items for reviewers

- [ ] Confirm code-signing certificate is applied before production rollout
- [ ] Confirm least-privilege service account / SYSTEM context is acceptable
      per policy for this use case
- [ ] Confirm logging retention/location complies with data handling policy
- [ ] Confirm RBAC scoping for Intune Win32 app publishing is reviewed
      alongside this code
- [ ] Confirm the default `C:\ProgramData` ACL (`BUILTIN\Users: Read &
      Execute`) is unmodified by GPO in the target environment - the file
      staging described above relies on this default rather than an
      explicit per-folder ACL grant
