# Deployment guide — from clone to a working SOC

Step-by-step path from two fresh git clones to a live, cron-driven SOC.
Written for someone who has not touched this setup before. For what the
system *is* and how it behaves once running, see `README.md` and
`soc-structure/overall.md`; this document is only about getting there.

**Scope note:** this guide documents the deployment as the scripts in this
repo actually implement it today — a single-host install, one Unix
operator account, one filesystem tree. See "Known limitations" at the
bottom before you deviate from the defaults (different install path,
different operator username, multi-host).

## 0. Prerequisites

- Linux with `systemd` (the provisioning scripts install `systemd-run`
  transient units and `.timer`/`.service` files — there is no non-systemd
  path).
- `sudo`/root access on the box.
- Packages: `build-essential` (or equivalent), a Rust toolchain (for
  `headless-siem`), `rsyslog`, `git`. `chattr`/`lsattr` (e2fsprogs) —
  used for append-only audit logs; most distros have it by default.
- The [Claude Code CLI](https://code.claude.com) installed, and either:
  - an Anthropic Console **API key**, or
  - a Claude subscription you can mint a long-lived token from via
    `claude setup-token`.
- A Unix user account for yourself as the human operator. The scripts as
  written assume this account is literally named `user` — see step 4 if
  yours is named differently.
- Two repos, cloned as siblings (`headless-siem` and `llm-soc-toolkit` next
  to each other) — several scripts and manifests reference the sibling
  path directly:
  ```bash
  cd /path/to/your/projects/root
  git clone <your-headless-siem-remote> headless-siem
  git clone <your-llm-soc-toolkit-remote> llm-soc-toolkit
  ```

## 1. Build and deploy headless-siem

The SOC has nothing to poll until the SIEM is receiving and indexing
logs. From `headless-siem/`:

```bash
make all                       # builds all 5 Rust binaries (release)
make test                      # optional but recommended
sudo bash config/systemd/install.sh release
```

`install.sh` installs the binaries to `/usr/local/bin/`, config to
`/etc/headless-siem/`, creates `/var/lib/headless-siem/` (owned by the
`user` account — see the limitations note below if that's not your
username), and installs+enables the ingestion/indexing systemd units.
Verify:

```bash
systemctl status headless-siem-normalized headless-siem-indexd
siemctl status
```

### Forward logs into it

At minimum, forward your own host's syslog so there's something to
triage. See `headless-siem/docs/forwarding-to-normalized.md` for the
rsyslog snippet (`omprog` → `/usr/local/bin/headless-siem-normalized`);
`headless-siem/config/rsyslog.d/50-headless-siem.conf` is the maintained
example, already installed to `/etc/headless-siem/rsyslog.d/` by
`install.sh` — symlink or `include()` it from your rsyslog config and
restart rsyslog. Confirm events are landing before moving on:

```bash
siemctl stats --after "$(date -u -d '10 min ago' +%Y-%m-%dT%H:%M:%S)"
```

If `siemctl stats` shows nothing, stop here and fix ingestion first — every
SOC role's first move is a `siemctl` query, and an empty pipeline just
produces four roles logging `result=clear` forever with nothing to show
for it.

## 2. Describe your environment: `soc_context/`, runbooks, and detections

Every triage decision a role makes is judged against "what does normal
look like here" — and that material is homelab-specific ground truth
that does not travel with the code. None of the following is optional
scaffolding; `runbooks/environment.md` is loaded on **every** analyst run
and the per-source runbooks are what keeps a role from either missing a
real incident or filing a ticket for routine traffic. Do this before step
7 (verification) so the roles have something real to triage against, not
the previous deployment's homelab.

### `soc_context/` — network ground truth

This folder is the "what's actually on my network" reference an
investigation draws on — none of it is code, and none of it should be
copied from another deployment. Author your own:

- **`ip_plan.md`** — your subnet/VLAN/host inventory: what's on each
  network segment, which IPs are infrastructure vs. workstations vs.
  DMZ/test hosts. This is the authoritative source the other docs below
  are distilled from.
- **`architecture.md`** — a topology diagram plus a summary of your
  firewall/routing policy (default-allow-outbound vs. default-deny,
  which segments can reach which). Point it at your actual firewall
  config export if you keep one — sanitize secrets/keys/hashes out of it
  first if any role will read it, and keep an unsanitized copy (if you
  need one at all) outside every role's read path entirely, same pattern
  as `documentation/canary-hosts.md`.
- **`open-questions.md`** — a running list of network facts you haven't
  confirmed yet (an IP you can't identify, a VLAN whose purpose is
  unclear). Keeps unverified guesses out of `ip_plan.md`/`architecture.md`
  instead of silently treating them as confirmed.
- **`log-forwarding-setup.md`** — device-by-device instructions for
  getting your own infrastructure (router/firewall, hypervisor hosts,
  anything else) forwarding to `normalized`'s listen address/port. This
  is the one piece that's genuinely per-deployment; the shipped example
  is pfSense/Proxmox-specific and won't apply to different gear —
  rewrite it for whatever you actually run, using
  `headless-siem/docs/forwarding-to-normalized.md` as the generic
  rsyslog/journald recipe underneath it.
- **`cmdb/`** — optional. A host/VM inventory export (e.g. from a
  hypervisor), useful for cross-referencing an alert's source against
  "what is this machine" without a manual lookup each time. Skip it if
  you don't have a CMDB to export.
- **`baselines/`** — don't hand-write these. Once logs are flowing (step
  1), `soc-baseline.timer` (installed in step 5) runs
  `scripts/capture-baseline` daily and drops a `siemctl digest` snapshot
  here automatically. Let it soak for 3-7 days with no role touching the
  SIEM before writing runbooks from it — that's real noise-profile
  history to write "what normal looks like" from, instead of a guess.

### `runbooks/` — per-source triage guidance

`runbooks/environment.md` is the always-loaded cheat sheet: rewrite it
once `soc_context/` reflects your network — topology table, what normal
traffic looks like, and any standing "never auto-close" exceptions you
want every role to know without re-deriving them. The shipped template
includes an optional Canary section for intentionally-vulnerable test
hosts used as a live detection self-test — a real, useful pattern if you
run one; delete that section entirely if you don't.

Per-source runbooks (`runbooks/<source>.md`, one file per log source —
`sshd.md`, `haproxy.md`, etc. are the shipped examples) follow a fixed
shape: **What normal looks like**, **Known-benign pattern**, **Escalation
criteria**, **Canned queries**. A source with no runbook isn't a hard
blocker — the analyst prompt falls back to `environment.md` plus
first-principles judgment — but expect noisier ticket filing for that
source until one exists.

You don't have to write every runbook up front. Two ways they get
created:

1. **By hand**, anytime — write `runbooks/<source>.md` matching the
   shape above, from real `siemctl` queries against your own baseline
   data, not guesses.
2. **Drafted by tuner-dev, merged by you.** When a role hits a source
   with no runbook, it can file a ticket proposing one. tuner-dev has no
   write access to `runbooks/` itself (merging is deliberately kept a
   human decision, not something an unsupervised cron role commits
   unreviewed) — instead it writes the full proposed file content to
   `runbook-drafts/<same-filename>.md` for you to review and copy into
   `runbooks/` yourself. See `prompts/tuner-dev.md`'s runbook-drafting
   section.

### Detection use cases — adding a new Sigma rule

New detections live in `headless-siem/`, not here — a "use case" is a
Sigma YAML rule (per-event, `headless-siem/config/rules/*.yml`) or a
correlation chain (multi-event, `headless-siem/config/correlations.toml`).
Full how-to, including the condition-expression syntax and testing with
`--dry-run`: `headless-siem/docs/guide-detection-rules.md`. Document each
new rule as `headless-siem/docs/detections/<id>-<slug>.md` and add a row
to the catalog table in `headless-siem/docs/detections/README.md` — match
the shape of the 10 shipped per-event rules and 4 correlation rules
already listed there (ID, title, severity, source, ATT&CK reference).
Test against real traffic with the harness in
`headless-siem/tests/detections/`.

This isn't purely a one-time setup task — `tuner-dev` is the only SOC
role with write access to `headless-siem/config/`, and any new
detection it implements (from a `soclead` weekly trend-report proposal,
or a ticket you file yourself) goes out the same way: committed to a
branch, never merged directly. See
`documentation/tuner-dev-branch-merge.md` for reviewing and merging one.

## 3. Point llm-soc-toolkit at your ntfy channel

`config/notify.conf` ships with a placeholder `NTFY_TOPIC` — **do not
deploy this as-is**. Anyone who guesses or finds a topic string can read
(and inject fake) your SOC's notifications, since the public ntfy.sh
instance has no access control beyond topic secrecy. Generate your own
before doing anything else:

```bash
# from llm-soc-toolkit/
NEW_TOPIC="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"
sed -i "s/^NTFY_TOPIC=.*/NTFY_TOPIC=\"$NEW_TOPIC\"/" config/notify.conf
```

Subscribe to that topic in the ntfy phone app (or `ntfy.sh/<topic>` in a
browser) so you'll actually see what the SOC sends you. `NTFY_SERVER` in
the same file can point at a self-hosted ntfy instance instead of the
public one — see `documentation/escalation.md`.

## 4. If you're not installing at the default path/user

Every provisioning script under `soc-structure/provision/` and every unit
under `config/systemd/` hardcodes `SOC_ROOT=/home/user/projects/llm-soc-toolkit`
and, in most of them, an operator account named `user`. This is the
single biggest gap between "works on the original homelab box" and "works
anywhere" — see "Known limitations" below. If your clone lives at exactly
`/home/user/projects/llm-soc-toolkit` and your operator account is `user`,
skip this step.

Otherwise, before running anything in step 5, edit every occurrence:

```bash
# from llm-soc-toolkit/
grep -rl 'SOC-ROOT-PATH\]' soc-structure/provision/ soc-structure/manifests/
grep -rl '/home/user/projects/llm-soc-toolkit' config/systemd/ scripts/
```

Each hit is a `SOC_ROOT=/home/user/projects/llm-soc-toolkit` line (provision
scripts), a `WorkingDirectory=`/`ExecStart=` line (systemd units), or a
path pattern (manifests) — replace the path, and in
`soc-structure/provision/01-users-and-perms.sh` also update `HUMAN=user`
to your own account name. There is no single config file or environment
variable that does this for you; it's a per-file edit. Do this *before*
step 5 — several scripts are idempotent but none of them re-derive the
path from a changed variable after the fact (e.g. already-installed
systemd units, sudoers files, and `/etc/soc/*-settings.json` won't update
themselves).

## 5. Run the provisioning scripts

Run these from `soc-structure/provision/` **in numeric order** — later
scripts depend on users/groups/files earlier ones create, and a couple
have hard prerequisites called out below. Every script is idempotent
(safe to re-run) and requires root.

```bash
cd llm-soc-toolkit/soc-structure/provision
sudo bash 01-users-and-perms.sh      # soc-* users, socroles group, filesystem perms
sudo bash 02-ticket-assign.sh        # ticket-assign helper + sudoers
sudo bash 03-tunerdev-checkout.sh    # tuner-dev's isolated headless-siem clone
                                      #   requires headless-siem/.git to already exist (step 0)
sudo bash 04-hooks-and-settings.sh   # PreToolUse hook + manifests, defaults to audit mode
sudo bash 05-siemctl-shim.sh         # siemctl PATH shim
                                      #   requires /usr/local/bin/siemctl to already exist (step 1)
sudo bash 06-restart-pipeline.sh     # soc-restart-pipeline + sudoers for analyst
                                      #   requires headless-siem's scripts/soc-restart-pipeline (step 1)
sudo bash 07-soc-notify-sudoers.sh   # sudoers for soc-notify
                                      #   requires 02 to have run first (reuses its sudoers alias)
sudo bash 08-ticket-route.sh
sudo bash 09-ticket-reassign.sh
sudo bash 10-ticket-close.sh
sudo bash 11-systemd-timers.sh       # installs AND enables+starts all cron timers — see caution below
sudo bash 12-rdap-lookup.sh
sudo bash 13-rust-toolchain.sh       # Rust toolchain + offline CARGO_HOME for tuner-dev
                                      #   requires 03-tunerdev-checkout.sh to have run first
```

**`11-systemd-timers.sh` enables and starts every timer immediately** —
by the time it finishes, `analyst` (hourly), `specialist` (hourly, +20m),
`tuner-dev` (every 5h, +40m), `soclead` (nightly + weekly), the daily
baseline capture, and the weekly session cleanup are all live and will
fire on their own schedule, spending real model calls. If you want to
verify each role manually before letting cron loose (recommended — see
step 7), create the kill switch **before** running this script:

```bash
sudo touch PAUSED && sudo chown root:socroles PAUSED && sudo chmod 640 PAUSED
```

Every role invocation and `soc-notify` call checks for this file first
and silently no-ops if it's present, so the timers can be live without
anything actually running yet. Remove it (`sudo rm PAUSED`) once you're
ready to go live in step 8.

## 6. Set up credentials for unattended runs

None of the provisioning scripts do this — it's a manual step every time
because it involves either a secret (API key) or an interactive login
(`claude setup-token`). `scripts/soc-run-role` looks for, in order:

1. `/etc/soc/<role>.key` or `/etc/soc/anthropic.key` — a plain
   `ANTHROPIC_API_KEY=sk-ant-...` file (Console API key). Preferred for
   production: works with `--bare` isolation and doesn't share your own
   interactive Claude Code usage/quota.
2. `/etc/soc/<role>.oauth` or `/etc/soc/oauth-token` — a subscription
   token from `claude setup-token`.

Pick one path. For an API key (simplest to reason about for a first
deployment):

```bash
echo 'ANTHROPIC_API_KEY=sk-ant-...' | sudo tee /etc/soc/anthropic.key
sudo chown root:root /etc/soc/anthropic.key
sudo chmod 600 /etc/soc/anthropic.key
```

For a subscription token instead:

```bash
claude setup-token                     # interactive; prints a long-lived token
echo 'CLAUDE_CODE_OAUTH_TOKEN=...' | sudo tee /etc/soc/oauth-token
sudo chown root:root /etc/soc/oauth-token
sudo chmod 600 /etc/soc/oauth-token
```

Be aware a shared subscription token means unattended cron runs and your
own interactive sessions draw from the same usage window — see
`soc-structure/runner-and-permissions.md` §9 (Known gaps) and
`documentation/running-roles-manually.md`'s Gotchas section.

## 7. Verify before going live

With `PAUSED` in place (step 5) and credentials installed (step 6):

```bash
# See the exact command each role would run, without running it
sudo scripts/soc-run-role --print analyst

# Actually run one role and watch it live (this DOES spend a real call,
# even with PAUSED present -- a manual invocation is deliberate, not cron)
sudo scripts/soc-run-role --watch analyst
```

Do this for all four roles at least once. Confirm:

```bash
sudo scripts/soc-ticket list                       # any tickets filed look sane
sudo tail agent-logs/*.log                          # every role logged a line
cat /etc/soc/hook-mode-analyst 2>/dev/null || cat /etc/soc/hook-mode
                                                     # should read "audit" at this point
```

Audit mode (the default `04-hooks-and-settings.sh` leaves you in) logs
out-of-manifest tool calls to `permission-audit/<role>.log` instead of
blocking them — this is the intended way to shake out manifest gaps
against your own environment before switching to enforcement. Expect a
few `AUDIT-NOMATCH` lines on a first run against a log environment
different from the one the manifests were tuned against; that's normal,
not a failure.

## 8. Go live

```bash
sudo rm PAUSED
```

Cron (installed and already enabled by step 5's `11-systemd-timers.sh`)
takes it from there. Day-to-day operation — reading/closing tickets,
running a role out-of-cycle, checking deploy drift, reviewing a
tuner-dev branch — is covered in:

- `.claude/skills/soc-tools/SKILL.md` — command reference
- `documentation/ticket-handling.md` — tickets
- `documentation/running-roles-manually.md` — manual role runs
- `documentation/tuner-dev-branch-merge.md` — reviewing tuner-dev's fixes

## 9. Move to enforce mode

Once audit mode has run long enough that you're not seeing new
`permission-audit/` entries for anything legitimate (a few days of real
traffic is a reasonable bar), flip each role:

```bash
echo enforce | sudo tee /etc/soc/hook-mode-analyst
sudo scripts/soc-build-settings analyst
# repeat per role: specialist, tuner-dev, soclead
```

`soc-build-settings` regenerates `/etc/soc/<role>-settings.json` from the
manifest + mode file — it's the only thing that actually changes
behavior; editing `hook-mode-<role>` alone does nothing until you rerun
it. Fully reversible (flip back to `audit` + rerun) if enforce mode turns
out to be denying something legitimate.

---

## Known limitations (read before publishing/relocating)

This guide describes what actually works today, including its rough
edges:

- **Hardcoded install path and username.** Every provisioning script and
  systemd unit assumes `/home/user/projects/llm-soc-toolkit` and an
  operator account named `user` (step 4). There is no templating
  mechanism — relocating means hand-editing every file that matches
  `grep -rl SOC-ROOT-PATH`.
- **Undeclared cross-repo build order.** `05-siemctl-shim.sh` and
  `06-restart-pipeline.sh` hard-fail if `headless-siem` hasn't been built
  and installed first; nothing enforces or checks this automatically
  beyond the scripts' own existence checks.
- **`11-systemd-timers.sh` enables all cron immediately** on first run —
  there's no "install but don't start" mode. Use the `PAUSED` flag (step
  5) if you want a dry-run window first.
- **Credential provisioning (step 6) is entirely manual** and undocumented
  anywhere except this guide and scattered prose in
  `runner-and-permissions.md` — there's no script for it, by nature of it
  requiring either a secret or an interactive login.
- **The shipped `config/notify.conf` topic is a placeholder, not a
  usable value** (step 3) — this is the one item in this list that
  isn't just a portability gap: deploying it unchanged means your
  notifications never actually send (or worse, if you forget to change
  it and someone else also never changed theirs, you'd share a topic).
  Generate your own before going live.

None of these block a single-host deployment that matches the defaults —
they only matter if you're relocating, multi-hosting, or preparing this
repo for redistribution.
