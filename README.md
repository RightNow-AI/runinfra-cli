# @runinfra/cli

Sign in from your terminal and pull the optimized model packages your workspace
owns.

```console
$ npm install -g @runinfra/cli
$ runinfra login
$ runinfra pull <slug> --out ./models
```

Replace `<slug>` with the slug shown on your package's page under
**Optimized models** on runinfra.ai, for example
`qwen3-6-27b-fp8cd-v3-mlponly-h100-vllm`.

---

## Install

<!-- Release note for the next editor: when the installer and the wheel are
     actually published, the standalone line becomes the lead command in the
     block above and its Status cell becomes "Live". Do not promote a row
     before fetching its artifact and installing from it: the Status column
     is the only thing standing between a reader and a command that 404s. -->

Three ways in, all live. These kits get pulled onto GPU hosts, and a GPU host
often has Python but no Node, so pick whichever matches the machine you are
standing on:

| Channel | Command | Reach for it when |
| --- | --- | --- |
| Standalone | `curl -fsSL https://raw.githubusercontent.com/RightNow-AI/runinfra-cli/main/install.sh \| sh` | The box is bare. No Node, no Python, the download brings its own runtime. |
| Python | `pip install runinfra-cli` | The machine already lives in Python. |
| Node | `npm install -g @runinfra/cli` | The machine already lives in Node 20 or newer. |

On Windows the standalone line is
`irm https://raw.githubusercontent.com/RightNow-AI/runinfra-cli/main/install.ps1 | iex`.

This table deliberately carries **no version and no status column**. It used to
carry both, and both rotted: after the release that took every channel live, a
reader on npm was still being told that two of the three did not exist and that
the client was two versions behind. A number written into prose is a number
nobody updates. For what is actually published right now, ask the registries:
`npm view @runinfra/cli version` and `pip index versions runinfra-cli`.

All three channels publish the same version at the same time and put the same
`runinfra` command on PATH: the standalone and Python channels repackage the
client that is already on npm rather than changing it. So `runinfra --version`
reads the same however it
arrived, and every command in this document behaves identically. What differs
is only what has to be on the machine first:

- **Standalone and Python** install one compiled executable with the runtime
  inside it. Nothing else is required, which is the whole point on a host you
  did not build. Note the distribution name: `pip install runinfra-cli` is
  this tool, `pip install runinfra` is the inference SDK, a different product
  for calling an endpoint from your code.
- **npm** installs the same program as JavaScript and runs it on the Node you
  already have. It has **zero runtime dependencies** by design, so it installs
  quickly and runs cleanly inside a slim container or a locked-down host.

Rather not install anything globally? The npm channel also runs through npx,
for example `npx @runinfra/cli pull <slug>`.

If your registry cannot find `@runinfra/cli`, the release has not reached it
yet. Run the CLI from a checkout instead, see [Development](#development).

---

## Verifying a release

Every release publishes `SHA256SUMS`, which lists the sha256 of each binary,
and `SHA256SUMS.sig`, an Ed25519 signature over that file.

`install.sh` checks both for you. It carries the public key **inside the
script** rather than fetching it, because a key downloaded from the same host
as the binary proves nothing: whoever can replace one can replace the other and
serve a matching pair. It verifies the signature before it reads a single hash
out of `SHA256SUMS`, and a bad signature ends the install rather than printing
a warning.

A **missing** signature ends the install too, when the artifacts came from a
release. An attacker who can serve you a swapped binary can also delete the
signature that would expose it, so a check that disappears on request is not a
check. If you are deliberately mirroring a release, or installing one published
before the signing key existed, `RUNINFRA_ALLOW_UNSIGNED=1` skips it and says
so, and artifacts taken from your own `--base-url` are never held to this rule.

Being unable to **perform** the check is the one case that stays a warning. If
the host has no `openssl`, or none that can do Ed25519, `install.sh` says so on
one line, names that exact reason, and continues on the checksum alone.
Refusing to install on a minimal container would cost more than it buys, and
the checksum still refuses a bad download. On macOS it looks past the LibreSSL
at `/usr/bin/openssl`, which cannot do the job, and tries the Homebrew
`openssl@3` locations before it gives up.

`install.ps1` does not check the signature. Windows PowerShell 5.1 has no
Ed25519 and .NET only gained one in 8, so it verifies the checksum, prints the
command below, and tells you which check it skipped rather than letting you
assume both ran.

To check a release by hand, save this as `runinfra-release.pub`:

```
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAYkEJIc7GfRAHAvUXcY/jrtnwFj53XZNDoXE6cAkOxYk=
-----END PUBLIC KEY-----
```

Its fingerprint is sha256 over the raw 32 byte key, and you can derive it from
the file you just saved rather than taking this line on trust:

```console
$ openssl pkey -pubin -in runinfra-release.pub -outform DER | tail -c 32 | sha256sum
5b2c8f637c0cd00a61ec6f126e5a9493c022ef1ea5be70fdd3ef4adf55801532
```

Then, in the directory holding the downloaded files:

```console
$ openssl pkeyutl -verify -pubin -inkey runinfra-release.pub -rawin -in SHA256SUMS -sigfile SHA256SUMS.sig
Signature Verified Successfully

$ sha256sum --ignore-missing -c SHA256SUMS
runinfra-linux-x64: OK
```

Run them in that order. The signature is what makes the checksum worth
checking: `SHA256SUMS` arrives from the same place as the binary, so anyone who
can swap the binary can swap its recorded hash to match. Verify the signature
first, then let the verified `SHA256SUMS` speak for the bytes.

Two things that are a failed check rather than a bad file. If the signature is
published base64 encoded rather than as 64 raw bytes, decode it first and point
`-sigfile` at the result, `base64 -d SHA256SUMS.sig > SHA256SUMS.sig.raw`, with
`-D` instead of `-d` on macOS. And
`-rawin` needs OpenSSL 1.1.1 or newer: the `openssl` on a stock macOS is
LibreSSL, whose `pkeyutl` has no `-rawin` at all, so it answers with a usage
error rather than a verdict. Read that as "not checked", not as "bad", and
install OpenSSL through Homebrew if you want the real answer.

### What a good signature proves

It proves the RunInfra release pipeline signed that file with the private half
of the key above, and that nothing has altered it since.

It does **not** prove that pipeline was not subverted. The signing key lives in
CI, so anyone who could steal the release token or edit the release workflow
could also reach the key and sign whatever they wanted. What this closes is a
release asset altered after publication, and a mirror or CDN serving something
other than what was published. Both are real attacks and both are worth
closing. Neither is the same thing as the download being tamper proof, and we
do not claim it is.

---

## What the CLI never does

- **It never sees your password.** Sign-in happens in your browser, in your
  existing RunInfra session. The CLI only ever holds an authorization code and,
  after the exchange, the key that code bought.
- **It never asks you to paste an API key.** You do not create a key, copy a
  key, or store a key by hand. Approving in the browser mints one, the CLI
  writes it to a file only you can read, and revoking it in Settings kills it.
- **It never prints the key.** `whoami` and `logout` show a redacted form
  (`rp_k...8fq2`). No other code path renders it.
- **The key it holds cannot spend money.** CLI keys carry `purpose = 'cli'`.
  The inference gateway refuses every purpose that is not `customer`, so a
  leaked credentials file cannot be turned into inference spend. It opens
  exactly one door: downloading a package your workspace already owns.

---

## Commands

| Command | What it does |
| --- | --- |
| `runinfra login [--device]` | Connects this terminal by having you approve it in a browser. |
| `runinfra pull <slug> [--out DIR] [--concurrency N]` | Downloads a package this workspace owns. Resumable. |
| `runinfra logout` | Deletes the local credential and tells you where to revoke the key. |
| `runinfra whoami` | Shows what this machine has stored, and when its access expires. |

---

## `runinfra login`

### What actually happens today

There are two flows, and the CLI picks for you.

**On a machine with a browser**, `runinfra login` opens the approval page
itself, and the approved code is delivered straight back to a listener on
`127.0.0.1`. You click Approve and the terminal connects on its own. If that
listener cannot be reached, the page shows the code so you can paste it into
the prompt that is already waiting, and the sign-in still completes.

**On a headless box** reached over SSH, in CI, or with no graphical display,
there is nothing to open, so the CLI prints a short code and you type it into
the page on whatever device does have a browser. It never puts the code in a
link: a link that arrives with the code already in it did not come from
RunInfra.

### On a laptop

```console
$ runinfra login
Opened your browser to approve this terminal.
  https://runinfra.ai/cli/authorize?request=3b1f2e9c-illustrative-request-id
Waiting for approval. This request expires in 10 minutes.
  Or paste the code shown on the approval page and press Enter:
Connected to workspace <your-workspace-id>.
  Credentials stored at /home/mona/.config/runinfra/credentials.json
  This access expires 2026-10-24T09:14:02.118Z.
  Revoke this terminal any time from Settings, API keys.
```

`Waiting for approval` repaints itself in place on a terminal, and is logged
once every ten seconds when the output is piped to a file.

### On a headless SSH box

Identical, with a different reason line. The CLI does not try to open a browser
over SSH, in CI, or on a machine with no graphical display: launching
`xdg-open` there prints a stack trace and hangs.

```console
mona@gpu-07:~$ runinfra login
Using the device flow because this is an SSH session.
To connect this terminal:
  1. On any device, open  https://runinfra.ai/cli/authorize
  2. Type this code:      T4WX-9BQH
The page will not fill the code in for you. If a link ever arrives with the code already in it, it did not come from RunInfra.
  Waiting for approval, 891s left
Connected to workspace <your-workspace-id>.
  Credentials stored at /home/mona/.config/runinfra/credentials.json
  This access expires 2026-10-24T09:14:02.118Z.
  Revoke this terminal any time from Settings, API keys.
```

`runinfra login --device` skips the browser attempt entirely and prints the
code immediately. It is a convenience, not a requirement.

The code is what you type, never what you click. The page has no field that can
be prefilled from a link, and the CLI discards the RFC 8628
`verification_uri_complete` field precisely because a code-bearing link is how
an attacker gets a victim to approve the **attacker's** terminal.

### What the browser shows

The approval page names the account, the workspace, the device label
(`user@host`, sent by the CLI), the code you typed, and the one thing it
grants: downloading optimized model packages the workspace already owns.
Approving requires a role that can deploy in that workspace. A viewer sees
"Not available for this role" instead of an Approve button, because a viewer
approval would mint a key that is refused on its first use.

### Timing and limits

- A device code is valid for **15 minutes**. After that the CLI stops polling
  and says so.
- Polling starts at one request every **5 seconds** and backs off by five more
  seconds each time the server says `slow_down`.
- The minted key lives **90 days**, then `pull` refuses locally and asks you to
  sign in again. Revoking from Settings ends it sooner.

---

## Where credentials live

One file, `credentials.json`, holding the key, the API base it was minted
against, the workspace id, the granted scope, and the expiry. No password, no
refresh token, no cookie.

| Platform | Path | Protection |
| --- | --- | --- |
| Linux, macOS | `$XDG_CONFIG_HOME/runinfra/credentials.json`, else `~/.config/runinfra/credentials.json` | Directory `0700`, file `0600` |
| Windows | `%LOCALAPPDATA%\runinfra\credentials.json` | Directory ACL rewritten to the current user only |

`RUNINFRA_CONFIG_DIR` overrides both, for CI and for mounted volumes.

macOS purists would expect `~/Library/Application Support`. Every CLI already on
that machine (gh, aws, docker, kubectl) uses `~/.config`, and matching the
neighbours beats matching the platform guideline for a file people occasionally
delete by hand.

Windows uses `%LOCALAPPDATA%` rather than `%APPDATA%` so a roaming profile never
syncs a live API key around a domain. `chmod` means nothing there (Node maps it
to the read-only attribute), so the directory ACL is rewritten instead:

```console
icacls "%LOCALAPPDATA%\runinfra" /inheritance:r /grant:r "DOMAIN\user":(OI)(CI)F
```

`/inheritance:r` drops inherited entries, which on a domain machine routinely
include Administrators and SYSTEM. `/grant:r` replaces any existing grant
instead of adding a second one. `(OI)(CI)F` is object- and container-inherit
full control, so the file created inside inherits it.

If that call fails, the CLI **says so** rather than implying a protection it did
not apply:

```console
warning: Could not restrict C:\Users\mona\AppData\Local\runinfra (icacls exited with code 5). The API key is protected only by your Windows profile permissions.
```

The mode is also applied with an explicit `chmod` on POSIX, because
`writeFile`'s `mode` option only applies when it creates the file: overwriting an
existing `0644` credentials file would otherwise keep the loose mode.

---

## `runinfra whoami`

Reports what **this machine** has stored, and labels it as such. There is no
identity endpoint on the CLI surface, so this does not claim a round trip it did
not make. A key revoked from Settings five minutes ago still shows here, and
fails on your next `pull`.

```console
$ runinfra whoami
Workspace  <your-workspace-id>
Key        rp_k3n9 (rp_k...8fq2)
Grants     catalog:download
Endpoint   https://runinfra.ai
Connected  2026-07-26T09:14:02.118Z
Expires    2026-10-24T09:14:02.118Z (in 2159h 58m)
This is what this machine has stored. Access may have been revoked from Settings, API keys since it was granted.
```

The fields go to stdout and the closing sentence to stderr, so
`runinfra whoami > terminal.txt` captures the facts without the caveat.

---

## Revoking access

Two different actions, and the CLI is careful not to confuse them.

**`runinfra logout` removes the local file. It does not revoke the key.**

```console
$ runinfra logout
Removed this machine's credentials.
  The key rp_k3n9 (rp_k...8fq2) is still valid until 2026-10-24T09:14:02.118Z.
  To end its access now, revoke it in Settings, API keys on runinfra.ai.
```

That wording is deliberate. A lost laptop is not handled by deleting a file you
no longer have access to.

**To actually end a terminal's access:** open **Settings, API keys** on
runinfra.ai. Every terminal you connected is listed there as
`RunInfra CLI: user@host`, with its prefix, when it was created, and when it was
last used. Revoke the row. The next command that terminal runs is refused:

```console
$ runinfra pull qwen3-6-27b-fp8cd-v3-mlponly-h100-vllm
error: This terminal's access was revoked.
  Run `runinfra login` to connect it again.
```

Revocation takes effect on the next request, and your role in the workspace is
re-read on every request too. Someone removed from a workspace, or demoted below
deploy, loses CLI access immediately rather than at their next key rotation.

One honest limit: a download URL already minted stays valid for its 30 minute
lifetime. Revoking stops new downloads from starting, it does not reach into a
transfer already in flight.

---

## `runinfra pull`

```console
$ runinfra pull qwen3-6-27b-fp8cd-v3-mlponly-h100-vllm --out /data/models
Downloading kit.zip (41.2 GB) into /data/models
  kit.zip  [########----------------]  33.4%  13.8 GB / 41.2 GB  92.4 MB/s  ETA 49m 12s
Transferred 41.2 GB in 1h 14m.
  Checksum verified.
Saved kit.zip.
/data/models/kit.zip
```

The final path is the only thing on stdout, so `MODEL=$(runinfra pull ... )`
works and progress does not pollute it.

Options: `--out DIR` (defaults to the working directory) and `--concurrency N`
(1 to 16, defaults to 8).

### How resume works

Interrupt it. Run the same command again.

```console
^C
Stopping. Run the same command again to resume.
error: Download interrupted.
  Run the same command again to resume from the bytes already on disk.

$ runinfra pull qwen3-6-27b-fp8cd-v3-mlponly-h100-vllm --out /data/models
Resuming kit.zip: 13.8 GB of 41.2 GB already on disk.
  kit.zip  [##########--------------]  41.7%  17.2 GB / 41.2 GB  88.1 MB/s  ETA 46m 30s
```

A second Ctrl-C exits immediately without finishing the write in progress.

Two files carry the state. `<name>.part` holds the bytes, preallocated to the
final size so a full disk is discovered now rather than at 90%.
`<name>.part.json` records which byte ranges are **durable**: a range is written
to that file only after the data is flushed to disk, so a power cut can lose
work but can never claim bytes that are not there.

Resume is refused, and the partial file discarded, in three cases. Each one
prints why:

- **The sidecar is missing or unreadable.** The `.part` is preallocated, so its
  length says nothing about which bytes are real. Guessing would produce a file
  that passes every check except the checksum, hours later.
- **The package was republished while you were downloading.** Version, size or
  ETag moved. Continuing would splice two different artifacts into one file.
- **The final file already exists at a different size.** Nothing is overwritten;
  you are told to move it or pass a different `--out`.

Everything else resumes. A dropped connection retries the affected chunk a few
times with backoff before giving up. The download URL is valid for 30 minutes and a large kit is not, so the
CLI renews it automatically 2 minutes before expiry and whenever storage refuses
a stale signature. Every renewal re-checks that the artifact is still the same
one.

### Verification

When the catalog published a sha256 for the package, the CLI hashes the file and
compares. A mismatch renames nothing, so bad bytes never appear under the final
name:

```console
error: The downloaded bytes do not match the published checksum for qwen3-6-27b-fp8cd-v3-mlponly-h100-vllm.
  The partial file was left at /data/models/kit.zip.part. Delete it and run the command again.
```

When the package publishes no checksum, the CLI says the file is **UNVERIFIED**
rather than implying it checked something.

### Before it writes anything

`pull` proves entitlement first, then probes the real size, then checks free
space against what is **left** plus 5% headroom. The failure you are most likely
to hit happens in the first two seconds rather than in hour four:

```console
error: Not enough free space in /data/models: 12.4 GB available, 28.7 GB needed.
  Free some space or pass --out to a larger volume, then run the same command again to resume.
```

---

## Exit codes

Scripted use is a first-class case, so failures are grouped rather than all
being `1`.

| Code | Meaning | Retry? |
| --- | --- | --- |
| 0 | Success | |
| 2 | Bad usage, or an unsupported Node runtime | No |
| 3 | Not signed in, denied, expired, or revoked | After `runinfra login` |
| 4 | The workspace does not own the package, or its files are not published yet | No |
| 5 | Network or server failure | Yes |
| 6 | Integrity failure: checksum mismatch, or the artifact changed mid-download | Start over |
| 7 | No space, or the destination is not writable | After freeing space |
| 130 | Interrupted | Yes, it resumes |

---

## Environment

| Variable | Purpose |
| --- | --- |
| `RUNINFRA_API_BASE` | Point at another deployment. Plaintext `http://` is accepted **only** for a loopback host, because the sign-in response carries a live API key. |
| `RUNINFRA_CONFIG_DIR` | Where credentials are stored. Overrides the platform default. |

The base a key was minted against travels with the key. If you sign in against a
preview deploy and then run against production, the CLI warns and uses the base
the key belongs to rather than sending that credential to a host that never
issued it.

---

## The HTTP contract

Every path and field this CLI speaks lives in `src/endpoints.ts`, read off the
routes as built.

| Route | Purpose |
| --- | --- |
| `POST /api/cli/device/init` | Start the device flow, returns the device code and the code you type |
| `POST /api/cli/device/poll` | Poll for approval, returns the key once approved |
| `POST /api/cli/device/loopback-init` | Start the browser flow, returns the request id the approval page opens |
| `POST /api/cli/token` | Loopback authorization code exchange, the browser flow's final step |
| `GET /cli/authorize` | The approval page, browser only |
| `GET /api/catalog/<slug>/download` | Dual auth, accepts a `purpose='cli'` bearer key |

Path choices are forced by the CSRF origin check: `/api/cli/token` and
`/api/cli/device/` are exempt from it, because no non-browser HTTP client sends
`Origin`. `/api/cli/authorize` is **not** exempt (that one is the browser
approving with session cookies), so the CLI never calls it. **Any new
CLI-called POST route must live under one of the two exempt prefixes or it will
403 on every platform.**

### Refusal envelope

Sign-in routes answer OAuth-shaped `{ "error": "<code>" }` (RFC 6749 5.2, RFC
8628 3.5) with `Retry-After` in the **header**, not the body:

```
invalid_request  invalid_grant  expired_token  access_denied
authorization_pending  slow_down  rate_limited  temporarily_unavailable
server_error  unsupported_code_challenge_method  invalid_scope
```

`invalid_grant` deliberately fuses replayed, unapproved, wrong-verifier,
wrong-redirect and never-existed, and the device poll answers `expired_token`
for a code it has never seen. The server refuses to be an oracle, so the CLI
does not try to reconstruct the distinction either.

The download route answers `{ ok: false, code }` with two vocabularies:
`not_found`, `artifact_not_ready`, `rate_limited` for the download itself, and
`missing_credentials`, `invalid_key`, `key_revoked`, `key_expired`,
`workspace_access_revoked`, `auth_unavailable` when the key did not hold up.
They map to different exit codes, so "your key was revoked" and "your workspace
does not own this" never collapse into one sentence.

### Sign-in success body

```jsonc
{ "apiKey": "rp_...", "keyPrefix": "rp_k3n9", "tokenType": "Bearer",
  "scope": "catalog:download", "workspaceId": "<your-workspace-id>",
  "expiresAt": "2026-10-24T09:14:02.118Z", "expiresIn": 7776000 }
```

Deliberately not called `access_token`: this is a RunInfra API key with no
refresh and no introspection endpoint, and borrowing the OAuth name would
promise a contract that does not exist.

### How sign-in is secured

OAuth 2.0 authorization code with PKCE (RFC 7636), plus the device shape
(RFC 8628) for headless hosts. The code verifier stays in the CLI process and is
never written, printed, or sent: only its SHA-256 challenge goes on the wire at
request time. Codes are stored hashed, so reading the database cannot complete a
pending sign-in. An approval is consumed by a single conditional UPDATE, so two
racing exchanges cannot both mint a key. Redirect targets are restricted to
loopback literals in the route, in the shared core, and in a database CHECK.

### Server-side gaps

Two things this CLI wants still do not exist. It degrades honestly rather than
pretending, and each becomes a small change here when it lands.

1. **Identity.** There is no `GET /api/cli/whoami`, so `whoami` reports the
   local credential and says so in those words. It makes no network call, and
   access it reports may already have been revoked from Settings.
2. **Revocation from the terminal.** `logout` removes the local credential and
   points you at Settings; it does not claim to have revoked the key, which
   stays valid until its expiry. Ending a key from the terminal itself is not
   offered yet: revoke it from **Settings, API keys** on runinfra.ai, which
   takes effect on that terminal's next request.

The browser sign-in flow that this document once listed as unbuilt now exists.
It is created by `POST /api/cli/device/loopback-init`, which takes
`{ codeChallenge, codeChallengeMethod, scope, redirectUri, deviceLabel }` and
returns `{ requestId }`. It sits under `/api/cli/device/` so it inherits the
origin exemption, which is why a route that is not a device route lives at
that path.

---

## Development

```console
node ../node_modules/typescript/bin/tsc -p tsconfig.json      # build to dist/
node ../node_modules/vitest/vitest.mjs run cli/src --root ..  # tests
node bin/runinfra.mjs --help                                  # run it
RUNINFRA_API_BASE=http://localhost:3000 node bin/runinfra.mjs login
```

Tests cover the pure logic, deliberately: range planning and resume arithmetic,
sidecar validation, the lease-refresh decision, per-platform browser command
selection, redirect construction for IPv4 and IPv6, credential and path
resolution, and every response parser. Nothing in the test suite opens a socket
to the internet.
