# @runinfra/cli

`runinfra` connects coding agents to RunInfra. Manage models, keys and status
from your terminal.

```console
npm install -g @runinfra/cli
runinfra login
runinfra agents
runinfra connect <agent>
```

The package has zero runtime dependencies and requires Node 22 or newer.

Bundled licenses and attribution are in `LICENSE` and `THIRD-PARTY-NOTICES.txt`.

## Install

| Channel    | Command                                                                                       |
| ---------- | --------------------------------------------------------------------------------------------- |
| Standalone | `curl -fsSL https://raw.githubusercontent.com/RightNow-AI/runinfra-cli/main/install.sh \| sh` |
| Python     | `pip install runinfra-cli`                                                                    |
| Node       | `npm install -g @runinfra/cli`                                                                |

On Windows, the standalone installer is:

```powershell
irm https://raw.githubusercontent.com/RightNow-AI/runinfra-cli/main/install.ps1 | iex
```

Every channel installs the same CLI release. Use `runinfra --version` to
check the installed release.

For a standalone download mirror, set `RUNINFRA_INSTALL_BASE_URL` or use
`--base-url` (`-BaseUrl` on Windows). Use HTTPS or an explicit `file:///` mirror.
Installers ignore `RUNINFRA_BASE_URL`.

The Windows installer checks SHA-256 only. The POSIX installer checks SHA-256
and the Ed25519 release signature when OpenSSL supports it; it reports when
signature verification is unavailable. A missing signature on a release is
refused unless you set `RUNINFRA_ALLOW_UNSIGNED=1`.

## Verifying a release

Download the release's binary, SHA256SUMS and SHA256SUMS.sig from the same
GitHub release. Verify the signature before trusting the manifest, then compare
the binary's SHA-256 checksum with its entry in SHA256SUMS.

Save the pinned public key as runinfra-release.pub from:
https://raw.githubusercontent.com/RightNow-AI/runinfra-cli/main/runinfra-release.pub

The SHA-256 fingerprint of the raw 32-byte Ed25519 public key is:

```text
5b2c8f637c0cd00a61ec6f126e5a9493c022ef1ea5be70fdd3ef4adf55801532
```

With an OpenSSL version that supports Ed25519, verify the manifest:

```console
openssl pkeyutl -verify -pubin -inkey runinfra-release.pub -rawin -in SHA256SUMS -sigfile SHA256SUMS.sig
```

A CI-held key proves the artifact came out of this pipeline and nothing more.

## Updates

`runinfra update --check` reports a newer stable release without installing.
Run `runinfra update` to review and approve installation, or add `--yes` to
approve it in a script. `--version X.Y.Z` selects a specific newer stable
version. Equal versions, downgrades and prereleases are refused when pinned.
`--check --version X.Y.Z` confirms that the exact public release exists and
is final before reporting it as available.

Each installed channel keeps its own installer:

| Channel | Update command |
| --- | --- |
| npm | `npm install -g @runinfra/cli@<target>` |
| Python | `<python> -m pip install --upgrade runinfra-cli==<target>` with the interpreter that launched the CLI |
| pipx | `pipx upgrade runinfra-cli` |
| Standalone | Downloads and verifies the signed release, then replaces the executable and notices |

pipx manages its own package version, so `--version` is refused for a pipx
installation. If an installer is missing or fails, the CLI reports its exit
code when available and prints the exact command to run by hand. Windows npm
uses the installed npm script with the running Node interpreter. Package
manager output inherits the terminal; with `--json` or redirected stdout,
installer output goes to stderr so the result stream remains parseable.

Standalone updates download the public release from GitHub. They verify the
Ed25519 signature with the public key embedded in the CLI, check the binary
and `THIRD-PARTY-NOTICES.txt` against the signed checksums. Staging saves
verified bytes without executing them. Before replacement, the updater
rechecks and probes a temporary copy beside the installed executable.
If replacement fails, it attempts to restore the previous executable and notices.
Update downloads and package installers never receive a credential.

Automatic updates run at most once per 24 hours after a command has learned
of a newer stable release. Linux and macOS standalone installations stage a
verified update in the background and apply it on the next start. Windows
standalone installations do not stage or apply automatic updates.
Windows standalone, npm and Python installations only show `Run: runinfra update`.
For npm and Python installations in the full-screen app,
select `Update available: <version>` and press Enter to exit the app, restore
the terminal and run the update in the foreground.

Set `RUNINFRA_NO_UPDATE=1` to turn off automatic updates and notices.
Automatic updates also stay off in CI, when stdin or stdout is redirected,
during `update`, `login` or `logout`, with `--json`, or while another update
holds the lock. The explicit `runinfra update` command remains available.

## Commands

| Command                                                                                                    | What it does                                                                                 |
| ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `runinfra login [--device] [--paste] [--json]`                                                             | Signs this terminal in.                                                                      |
| `runinfra logout [--local] [--disconnect-all] [--yes] [--json]`                                            | Signs out, optionally disconnecting every managed agent first.                               |
| `runinfra whoami [--json]`                                                                                 | Shows the stored terminal identity without printing a key.                                   |
| `runinfra status [--window 15m\|1h\|24h] [--offline] [--json]`                                             | Open live usage in a terminal.                                                              |
| `runinfra agents [--all] [--json]`                                                                         | Detects supported agents and never writes.                                                   |
| `runinfra connect <agent>... [--name NAME] [--model ID] [--key-source file\|env] [--preview] [--yes] [--json]` | Creates separate commands for relocatable agents. Use --name with one agent. |
| `runinfra connect --detected [--model ID] [--key-source file\|env] [--preview] [--yes] [--json]` | Prepares the same batch for every supported agent found locally.                             |
| `runinfra disconnect <agent>... [--force] [--keep-key] [--yes] [--json]` | Removes a named profile, or restores an in-place connection. |
| `runinfra models [--harness AGENT] [--json]`                                                               | Lists available models.                                                                      |
| `runinfra models set <agent> <model-id> [--yes] [--json]`                                                  | Changes one connected agent's model.                                                         |
| `runinfra models sync [--yes] [--verify] [--json]`                                                         | Refreshes connected agents from the current catalog.                                         |
| `runinfra keys [--json]`                                                                                   | Lists agent key prefixes.                                                          |
| `runinfra keys rotate <agent> [--yes] [--json]`                                                            | Replaces an agent key in safe order.                                                         |
| `runinfra keys revoke <agent> [--yes] [--json]`                                                            | Removes a named profile, including its sessions, or restores in-place settings, then revokes the agent key. |
| `runinfra keys revoke --id <keyId> [--yes] [--json]` | Revokes one agent key in the signed-in workspace, including a lost local record. |
| `runinfra keys cap <agent> <dollars\|none> [--yes] [--json]`                                               | Reviews, then sets or removes an agent spend cap.                                            |
| `runinfra account [--json]`                                                                                | Shows the signed-in account record.                                                          |
| `runinfra plan [--json]`                                                                                   | Shows the current plan, local reset times, limits and credits. |
| `runinfra plan buy <starter\|pro\|team> [--json]` | Opens plan checkout in your browser, then waits for the confirmed change. |
| `runinfra plan settings [--json]` | Opens plan settings in your browser, then waits for the confirmed change. |
| `runinfra doctor [--verify] [--offline] [--out DIR] [--json]`                                              | Diagnoses connections. It sends no paid request unless `--verify` is present.                |
| `runinfra update [--check] [--version X.Y.Z] [--yes] [--json]` | Checks for or installs a newer stable CLI release using its original channel. |
| `runinfra tui`                                                                                             | Opens the interactive terminal view.                                                         |
| `runinfra help [--json]`                                                                                   | Shows command help.                                                                         |
| `runinfra version [--json]`                                                                                | Shows the installed CLI version.                                                             |

Global aliases are `-h, --help` and `-V, --version`. Doctor accepts `-o, --out`
for its report directory. Options apply only to their listed commands.
Boolean options take no value. Choose either `--device` or `--paste` for login,
and either `--local` or `--disconnect-all` for logout.

Purchases and plan changes happen only in the browser. `runinfra plan` without a
plan says `No coding plan on this workspace.`. `runinfra plan buy` and
`runinfra plan settings` exit 5 when no change is confirmed within ten minutes.

Bare `runinfra` opens the interactive view when input and output are usable
terminals. It prints help when output is redirected or `RUNINFRA_NO_TUI=1` is
set. With an unusable terminal, `runinfra tui` prints the reason and help.

Sign-in uses a device code on remote terminals and machines without a local
browser. It checks the credential destination before approval and refuses to
overwrite credentials changed during the prompt. Re-login names the previous
terminal key before approval and revokes it after saving the new key. Replaced
shared keys stay active. Unsaved keys are identified by prefix after exit.
`login --json` reports `storage.restricted` for a completed save.

`logout --json` reports `serverRevocation` and `localDeletion` independently.
`localDeletion: "displaced"` means the key being signed out is no longer stored
in the credential file; its replacement was kept. Pasted shared keys and keys
in legacy format-1 files are not revoked by logout. They remain live until
expiry or explicit revocation in Settings, API keys.

## Coding plans

`runinfra plan` shows your plan, window use and reset times.
Status shows what pays now. Money totals count credits only.

At first TUI sign-in, choose **Pay as you go** or **Coding plan**.
Escape selects **Pay as you go**.
The question appears once per workspace when sales are open and no plan exists.
Tier prices come from the server. Only an owner can buy in the browser.
Plain `runinfra login` prints one offer hint.

`runinfra plan buy <starter|pro|team>` opens checkout.
`runinfra plan settings` opens Billing.
The CLI checks for a confirmed change for up to ten minutes.
Ctrl-C stops waiting. It does not cancel a browser purchase.

Connect selects a covered model for a serving plan, including OpenCode and
Command Code. Keys say which payer applies. Credits-only keys need credits.
Plan changes require browser confirmation. `keys cap` changes spend caps after
review. Key payment settings stay unchanged.
Rotate Credits-only keys in the dashboard to preserve their payer.

## Connect safety and consent

Relocatable agents use `<agent>-run` without changing their own settings.
Use `--name` for another launcher name. Profiles use `--key-source file`.
In-place agents say so in Review.

Enter opens the next step. Read Review to the end and clear its blockers.
Then Enter or `y` approves. Escape goes back. Held or pasted keys never approve.
If asked, paste harmless text once, then reread Review.
If blocked, use a supported terminal.

Agents, Models, Done and Status use aligned columns. Narrow terminals omit lower
priority columns; open the focused row's evidence to inspect the full facts.
Account supports Up and Down scrolling, including expiry and permissions.

Manual completion records your report locally. It does not change an agent's
configuration, send a paid probe, or claim that the connection is active. A failed
key handoff keeps the guide and error visible. Use `r` to retry that guide and
Enter to return to Manual; a successful retry leaves the full key hidden.

Recovery opens Review for the affected agent. Disconnect recovery shows the
original settings that will replace the reviewed current files. If restoration
already succeeded and key revocation failed, the next Review contains only the
retained key operation. Counts and previews describe the exact scope; changed
files or snapshots require a fresh Review.

`runinfra connect` detects first, resolves sign-in and models, and prepares
every file edit before asking once for the whole batch. The review includes:

- every destination file and its `+N/-M` line count;
- where the key will be placed;
- changes that need a restart;
- `Connect will send one request per agent using your workspace credits` for pay-as-you-go workspaces;
- For coding plan workspaces, verification uses the workspace funding policy.

Plain prompts require `y`. Scripts require `--yes`; without it, the command
exits 8 with the complete plan as `consent_required`. `--preview` permits
experimental agents. Approved connections write files and send paid requests.

Paid verification actions: `connect`, `keys rotate`, `doctor --verify`, `models sync --verify`.
Connect and keys rotate announce the count before paid verification.

Each connection and private key copy records the agent key's workspace ID and
name when reported. Before each paid request with a managed agent key, the CLI
checks that the exact recorded key is active in the scoped key service and belongs to both the reviewed workspace
and the terminal's current workspace. A mismatch sends no request and appears
in shell output and the TUI with a sign-in layer and recovery instructions.

To move an agent to the current workspace, use
`runinfra disconnect <agent> --keep-key`, then repeat the original
`runinfra connect <agent>` command with the same `--model`, `--key-source` and
`--preview` options and review the new connection. Alternatively, sign in to the key's workspace.
Disconnecting with `--keep-key` keeps the previous key without scheduling revocation.
Pending revocations proceed only after a review names their IDs and you approve, or through `runinfra keys revoke --id <keyId>`.
Revocation refuses keys still used by another connected agent or held in `RUNINFRA_API_KEY`.
Older state and journals without workspace identity remain explicitly unknown; paid
verification requires reconnecting.

`login --paste` stores a validated shared key privately and labels it
`shared key, pasted`. Connect keeps the workspace ID returned by free credit
metadata, checks it again before writing, and revalidates that exact shared
credential before the consented paid probe. Account identity and workspace names
remain unknown when not reported. Status reads credits without sending a paid
request. A credit service that omits workspace identity cannot authorize this
connection; use browser sign-in until the service reports the workspace ID.

Shared-key rotation is refused without changing keys or settings. Sign in through
the browser, then reconnect each affected agent with its own key. Keep the shared
key valid until every affected agent is replaced. Disconnect restores the saved
configuration and leaves the shared key valid.

`doctor` and `models sync` send no paid requests without `--verify`. With that
flag, they announce the request count before the first paid request. Doctor's
`--offline` and `--verify` options cannot be combined.
Online Doctor, including its terminal screen, checks service reachability with
one free service-status read. Offline Doctor skips that check and
reports why. Connect, disconnect and key rotation do not perform this service check.

Keys are never accepted on argv. Use `runinfra login`; do not pass a key through
a command-line flag or positional value. Full agent keys appear only in the
acknowledged live manual handoff for 20 seconds, never in receipts or saved logs.

## Output contracts

Human output is used on a terminal. `help` and `version`, including `--help`
and `--version`, also print plain text when stdout is redirected. Use
`runinfra help --json` or `runinfra version --json` for their JSON documents.
The flag aliases `runinfra --help --json` and `runinfra --version --json`
work too.
For other commands, redirected output is NDJSON using CliEvent v1:
`started`, `progress`, `note`, `warning`, `result`, `error`, and
`consent_required`. `--json` writes one final JSON document and nothing else
on stdout. Each command produces one final result document, carried in
`data.document` on the NDJSON `result` event.

`runinfra update --json` returns `schemaVersion: "runinfra.update/1"`,
`command`, `ok`, `exitCode`, `channel`, `currentVersion`, `targetVersion`,
`check`, `status`, `commandLine`, `installerExitCode`, `code` and `message`.
Unknown target, command, installer exit code and error code values are
`null`. Check success uses `available` or `current`; a verified standalone
swap uses `updated`; package manager success uses `installer-complete`.
Other statuses are `consent-required`, `cancelled`, `refused` and `failed`.

`runinfra plan --json` returns the validated `runinfra.cli.plan/1` resource directly.
Other results have the string `schemaVersion: "runinfra.<command>/1"`. Optional
numbers are `null` when absent or carry both `value` and `basis`. Unknown data
is displayed as `[unknown]` with its reason, never as a made-up zero. Machine
output and receipts use key prefixes. Measured and estimated values are
always qualified.

## Status honesty

`runinfra status` opens live usage in a terminal. `--window 15m|1h|24h`
selects the usage window. Defaults to 15m live, 24h in one-shot output.
15m is available only in the live view. `--offline` reads local state only.
`--json`, redirected output, CI, `--offline`, and `RUNINFRA_NO_TUI=1`
keep the one-shot local, service, account, and usage report.

A failed account read preserves local and service facts. Without sign-in,
usage is `[unknown] not signed in`.

The `runinfra.status/1` document carries local agent rows in `local.agents`.
Their `status` values describe current local evidence:

| Status | Meaning |
| --- | --- |
| `not-connected` | No connection record exists, including after a successful disconnect removes it. |
| `active` | Every recorded managed file matches its saved hash. |
| `modified` | A recorded file changed, or some managed files are absent while others remain. |
| `missing` | A non-manual connection record exists, but all its managed files are absent or no files were recorded. |
| `manual` | Setup is recorded as manual; file integrity cannot be checked. |

Online Status and Home read service metadata for free and never send paid requests.

## Exit codes

| Code | Meaning                                                            |
| ---- | ------------------------------------------------------------------ |
| 0    | success                                                            |
| 1    | unexpected internal error                                          |
| 2    | bad usage, unsupported runtime, or local precheck                  |
| 3    | not signed in, denied, expired, or revoked                         |
| 4    | entitlement or plan refused, or the requested agent, key or resource was not found |
| 5    | network, server, readiness, or requested measurement unavailable   |
| 6    | integrity or configuration verification failure                    |
| 7    | local preparation failed or storage is unavailable                 |
| 8    | consent required before the command may continue                   |
| 9    | consent was refused                                                |
| 130  | interrupted                                                        |

## Local files

Sign-in names this machine's previous terminal key before approval, including
workspace switches and paste sign-in. The new key is saved before the previous
terminal key is revoked. If saving fails, the previous key stays active.

The CLI uses the platform configuration directory, overridden by
`RUNINFRA_CONFIG_DIR`. Persistent and transient files include
`credentials.json`, `credentials.json.<random>.tmp`, `update-check.json`,
`update-check.json.<pid>.tmp`, and `update-check.json.lock`. Connection state,
snapshots, and locks remain under the existing `connect` subdirectory so prior
connections can be restored.

Standalone update staging lives in the private `updates` subdirectory.
On Windows, explicit updates save a transaction marker so a later start of
`runinfra.exe` or `runinfra.exe.old` can recover an interrupted swap. Cleanup removes only
backups whose size and checksum match that transaction. The two executable
renames are not atomic, so an interruption can leave the normal executable
path missing until recovery runs. Recovery needs a binary that includes this logic.
To recover by hand, rename `runinfra.exe.old` back to `runinfra.exe`, or rerun the installer.

An interrupted update can leave an executable `.update.lock` or a staging
`stage.lock`. If the CLI reports one, close all CLI processes and remove only
the named lock before retrying. The updater refuses uncertain lock ownership.
If rollback failed, restore the saved files before removing the lock.

## Environment

| Variable              | Purpose                                                                                   |
| --------------------- | ----------------------------------------------------------------------------------------- |
| `RUNINFRA_API_BASE`   | Points the CLI at another deployment. Plaintext HTTP is allowed only for a loopback host. |
| `RUNINFRA_CONFIG_DIR` | Overrides the platform configuration directory.                                           |
| `RUNINFRA_NO_TUI`     | Disables the interactive view.                                                            |
| `RUNINFRA_NO_UPDATE`  | Set to `1` to disable automatic updates and notices. |
| `RUNINFRA_REDUCED_MOTION` | Set to `1` for a still pending indicator. Nonempty `NO_COLOR`, non-TTY and dumb terminals also suppress motion. |

Configured proxy routing is unavailable in this build. Requests requiring a
proxy refuse before network IO. Explicit `NO_PROXY` or `no_proxy` host, suffix
and port exclusions permit direct requests, including loopback; those requests
refuse redirects. Proxy credentials are never included in diagnostics.

Doctor reports the actual terminal, credential, agent and retained snapshot
paths. POSIX mode and ownership evidence is separate from Windows ACL evidence.
On Windows, failed protection refuses a secret write, removes the empty
temporary and keeps the previous file. Doctor reports existing privacy
problems without changing permissions. Relative `XDG_CONFIG_HOME` is
ignored; macOS and other POSIX hosts keep the existing XDG configuration path.
A leading byte-order mark (BOM) in the credentials file is accepted.
Malformed credential JSON is reported as a parse
failure, never as a missing credential. CRLF JSON is accepted.

If the browser does not open, use the displayed sign-in URL. Remote TUI
sessions and `login --device` use a device code; plain headless login keeps
its shared-key fallback. Cancel any firewall prompt and use a device code.
