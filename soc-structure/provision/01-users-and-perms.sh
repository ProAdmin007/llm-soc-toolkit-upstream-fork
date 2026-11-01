#!/usr/bin/env bash
#
# 01-users-and-perms.sh
#
# Implements runner-and-permissions.md §2 (Unix users/groups) and §3
# (hard-layer filesystem ownership/modes). This is the "hard layer" that
# is enforced from day one (§1).
#
# Properties:
#   - IDEMPOTENT: safe to re-run after an interrupted/token-exhausted
#     session. Every step checks-before-creating or uses naturally
#     idempotent chown/chmod.
#   - Does NOT create the PAUSED flag (human-only, §3).
#   - Does NOT touch cron, invoke any model, or start any service.
#   - Requires root (useradd/chown). Run: sudo bash 01-users-and-perms.sh
#
# Refinements over the doc's illustrative examples:
#   - Role users get PRIMARY group socroles (not a private per-user
#     group) so files they create are group-readable cross-role by
#     default on the 750 folders, realizing §3.1 without per-folder
#     setgid. §5.4's private temp file stays private via mode 600.
#   - The human 'user' account is added to socroles for READ access
#     (write stays owner-only) and OWNS the dev/reference material, so
#     the git working tree stays developer-editable while roles remain
#     read-only (group has no write). Security-equivalent to root-owned:
#     'user' is a trusted sudoer and roles get identical read-only
#     access either way. Only true runtime role-data is role-owned;
#     secrets/staging/audit stay root.
#   - /home/user is 750, blocking soc-* traversal to the project; granted
#     execute-only via chgrp socroles + chmod 710 (Option B). Alternative
#     was relocating the tree to /srv (Option A, backlogged).
#
set -euo pipefail

SOC_ROOT=/home/user/projects/llm-soc-toolkit   # [SOC-ROOT-PATH] — only place the tree root is hardcoded
HOME_BASE=/var/lib/soc                        # system path; does NOT change under a future relocation
HUMAN=user   # the operator account: owns dev/reference material, retains read on runtime data

log() { printf '  %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo bash $0)"; exit 1; }
[[ -d $SOC_ROOT ]] || { echo "SOC_ROOT not found: $SOC_ROOT"; exit 1; }
getent passwd "$HUMAN" >/dev/null || { echo "operator account '$HUMAN' not found"; exit 1; }

echo "== group + users =="

if getent group socroles >/dev/null; then log "group socroles exists"; else
  groupadd --system socroles; log "created group socroles"; fi

for u in soc-analyst soc-specialist soc-tunerdev soc-soclead soc-infra; do
  if getent passwd "$u" >/dev/null; then
    log "user $u exists"
  else
    useradd --system \
      --home-dir "$HOME_BASE/${u#soc-}" --create-home \
      --shell /usr/sbin/nologin \
      --gid socroles --no-user-group \
      "$u"
    log "created user $u (HOME $HOME_BASE/${u#soc-}, primary group socroles)"
  fi
done

if id -nG "$HUMAN" | tr ' ' '\n' | grep -qx socroles; then
  log "$HUMAN already in socroles"
else
  usermod -aG socroles "$HUMAN"
  log "added $HUMAN to socroles (re-login needed for existing shells; use 'sg socroles -c' meanwhile)"
fi

# [SOC-ROOT-PATH] Option-B-only block — DELETE this if the tree relocates to /srv.
echo "== traversal: grant soc-* execute-only into /home/user (Option B) =="
# No ACL/package dependency: chgrp socroles + mode 710 gives socroles
# execute-only (traverse, no list) — stricter than the prior 750, since
# group loses read. Owner (user) keeps rwx. Reversible: chgrp user +
# chmod 750.
chgrp socroles /home/user
chmod 710 /home/user
log "chgrp socroles + chmod 710 on /home/user (traverse, not list)"

echo "== hard-layer filesystem ownership/modes =="
cd "$SOC_ROOT"

# Ownership model:
#   DEV/REFERENCE (git-tracked, we edit)  -> $HUMAN:socroles  (roles read via group, no group write)
#   RUNTIME role data (roles write)       -> soc-<role>:socroles
#   Neutral staging / audit / secrets     -> root
tree_perms() { # <path> <owner:group> <dirmode> <filemode>
  chown -R "$2" "$1"
  find "$1" -type d -exec chmod "$3" {} +
  find "$1" -type f -exec chmod "$4" {} +
}

# --- dev/reference material: operator-owned, roles read-only ---
for d in runbooks documentation cmdb soc-structure prompts baselines config; do
  tree_perms "$d" "$HUMAN:socroles" 750 640
done
tree_perms scripts "$HUMAN:socroles" 750 750   # helpers stay group-executable (soc-infra runs them via sudo)
log "dev/reference dirs -> $HUMAN:socroles"

# --- ticketing-system: parent operator-owned; role folders role-owned ---
chown "$HUMAN:socroles" ticketing-system; chmod 750 ticketing-system
chown "$HUMAN:socroles" ticketing-system/system.md; chmod 640 ticketing-system/system.md
tree_perms ticketing-system/analyst    soc-analyst:socroles    750 640
tree_perms ticketing-system/specialist soc-specialist:socroles 750 640
tree_perms ticketing-system/tuner-dev  soc-tunerdev:socroles   750 640
tree_perms ticketing-system/soclead    soc-soclead:socroles    750 640

# user/ : human inbox — operator-owned, group-writable so any role can
#         file directly; setgid so new files inherit socroles.
chown "$HUMAN:socroles" ticketing-system/user
find ticketing-system/user -type f -exec chown "$HUMAN:socroles" {} + 2>/dev/null || true
find ticketing-system/user -type f -exec chmod 640 {} + 2>/dev/null || true
chmod 2770 ticketing-system/user

# unassigned/ : neutral create-then-move staging; setgid+sticky (/tmp-like)
#               so a role can't delete another role's staged file.
chown root:socroles ticketing-system/unassigned
find ticketing-system/unassigned -type f -exec chown root:socroles {} + 2>/dev/null || true
find ticketing-system/unassigned -type f -exec chmod 640 {} + 2>/dev/null || true
chmod 3770 ticketing-system/unassigned
log "ticketing-system done"

# --- agent-logs: dir operator-owned; each <role>.log owner soc-<role> ---
chown "$HUMAN:socroles" agent-logs; chmod 750 agent-logs
[[ -f agent-logs/.gitkeep ]] && { chown "$HUMAN:socroles" agent-logs/.gitkeep; chmod 640 agent-logs/.gitkeep; }
for r in analyst specialist tuner-dev soclead; do
  u="soc-${r/tuner-dev/tunerdev}"
  # Pre-create, don't just conditionally chown: agent-logs/ is 0750 with no
  # group-write, so a role whose log file doesn't exist yet (its very first
  # run) can never create it itself -- it would hit a write-denied error
  # trying to log its own result, discovered live the first time soclead and
  # tuner-dev each ran for the first time after provisioning.
  touch "agent-logs/$r.log"
  chown "$u:socroles" "agent-logs/$r.log"; chmod 640 "agent-logs/$r.log"
done
log "agent-logs done"

# --- reports: soclead's runtime write target ---
tree_perms reports soc-soclead:socroles 750 640
log "reports done"

# --- non-LLM helper state (soc-infra only) ---
for d in .notify-count .watchdog-state; do
  mkdir -p "$d"; chown soc-infra:socroles "$d"; chmod 770 "$d"
done
log ".notify-count / .watchdog-state done"

# --- audit-mode violation logs (new; root dir so no role can rm a log) ---
mkdir -p permission-audit; chown root:socroles permission-audit; chmod 750 permission-audit
log "permission-audit created"

# --- secrets: NOT agent context, unreadable by socroles (owner root, 600) ---
#     applied LAST so it overrides the documentation/ tree_perms above.
#     Add any other ground-truth files a role should never read here too
#     (e.g. an unsanitized firewall config backup) -- keep a redacted
#     sibling readable if a role legitimately needs the non-secret parts.
for f in documentation/canary-hosts.md; do
  [[ -f $f ]] && { chown root:root "$f"; chmod 600 "$f"; log "locked $f (root 600)"; }
done

echo "== verification =="
echo "-- users --"; for u in soc-analyst soc-specialist soc-tunerdev soc-soclead soc-infra; do
  getent passwd "$u" | awk -F: '{printf "  %-15s home=%s shell=%s\n",$1,$6,$7}'; done
echo "  socroles members: $(getent group socroles | cut -d: -f4)"
echo "-- key paths --"
for p in ticketing-system ticketing-system/analyst ticketing-system/user \
         ticketing-system/unassigned agent-logs agent-logs/analyst.log \
         reports runbooks soc-structure scripts scripts/soc-notify \
         .watchdog-state permission-audit documentation/canary-hosts.md; do
  [[ -e $p ]] && stat -c '  %-42n %U:%G %a' "$p"
done
echo
echo "DONE. Next: ticket-assign + sudoers (see runner-and-permissions.md §4)."
