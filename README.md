# @runinfra/cli

Your coding agent sets up RunInfra's open models for you. Paste this prompt into the agent you want to connect:

```text
Set up RunInfra's open models in this coding agent for me. Read https://runinfra.ai/docs/tools-sdks/agent-setup.md and follow it step by step. If you cannot open links, run `npx -y @runinfra/cli@latest --help` and follow its FOR CODING AGENTS section. I approve sign-in in my browser. Before you install anything, change this agent's settings or spend money, show me the plan and wait for my yes.
```

Approve sign-in in your browser, then say yes to the setup plan your agent shows you. The plan names the files, keys, one short paid check and who pays. You never paste a key into chat.

To set it up yourself, run `runinfra` in a terminal.

Your agent runs this sequence, stopping for your approval at sign-in and before apply:

```console
runinfra whoami --json
runinfra login --device --no-wait --json
runinfra login --device --json --timeout 100
runinfra agents --json
runinfra plan --json
runinfra connect <agent> --json [--funding plan|credits]
runinfra connect <agent> --json [--funding plan|credits] --yes
runinfra doctor --json
```

It connects only itself, asks which payer to use when a Coding plan can pay, and relays the start command, model choice and restart instructions. A changed or used review requires a fresh review and yes. Preview connections also need your consent. Without a plan that can pay, it omits `--funding`, so the key uses credits now and can use a plan you add later.

Plan-funded connections add covered models; models added earlier stay, and any outside the plan pay from credits. Verification uses workspace credits for pay-as-you-go workspaces. For coding plan workspaces, verification uses the workspace funding policy.

`runinfra keys` lists agent key prefixes. To recover an unused key, review `runinfra keys revoke --id <keyId>` before approving revocation. `runinfra update --check` checks the update path for your install channel. The CLI refuses unsafe configuration changes.

`doctor` and `models sync` send no paid requests without `--verify`. `help` and `version`, including `--help` and `--version`, also print plain text when stdout is redirected. Scripts require `--yes`; without it, the command exits 8 with the complete plan as `consent_required`.

Guide: https://runinfra.ai/docs/tools-sdks/agent-setup

Run `runinfra help` for commands. Every channel installs the same CLI release.
Install with `npm install -g @runinfra/cli`. It requires Node 22 or newer, with zero runtime dependencies.
Other install channels for your agent: `pip install runinfra-cli`, or `curl -fsSL https://raw.githubusercontent.com/RightNow-AI/runinfra-cli/main/install.sh | sh`. On Windows:

```powershell
irm https://raw.githubusercontent.com/RightNow-AI/runinfra-cli/main/install.ps1 | iex
```

Bundled licenses are in `LICENSE` and `THIRD-PARTY-NOTICES.txt`.
The CLI stores sign-in privately in `credentials.json`, using `credentials.json.<random>.tmp` during atomic writes. Never open or share these files or Connect's key copies and snapshots.

The Windows installer checks SHA-256 only. The POSIX installer checks SHA-256 and the Ed25519 release signature when OpenSSL supports it. It reports when signature verification is unavailable.

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
