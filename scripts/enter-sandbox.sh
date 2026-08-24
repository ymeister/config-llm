#!/usr/bin/env bash
# Enter the hermetic dev sandbox. Run a command inside it.
#
#   enter-sandbox                     # interactive shell inside the box
#   enter-sandbox <cmd> [args...]     # run <cmd> inside the box
#
# This script builds a bubblewrap sandbox. Only the project and the box's home
# are writable. Everything else is read-only. The script then execs the given
# command inside the sandbox. The default command is `bash`.
#
# `nix develop` is one caller among others. The shellHook in shell.nix runs
# `enter-sandbox nix develop` for an interactive `nix develop`. The hook then
# runs a second time, inside the box. That second pass sets up the in-box
# environment. It then drops you at a prompt.
#
# The one host dependency is `nix`. Everything else comes from the dev shell,
# bwrap included.
#
# Multi-UID support. Some images run as a fixed non-root UID, such as postgres
# at 999, tempo at 10001, and prometheus at 65534. Those images start unmodified
# in this box. bwrap would otherwise make its own user namespace with a single
# UID in it, so this script makes the box's user namespace on the host instead.
# The command is `unshare --map-root-user --map-auto`. That command calls the
# host's setuid newuidmap and newgidmap. It maps inner UID 0 to our UID. It also
# maps our whole /etc/subuid range to the free inner IDs, 1 to N. This is the
# standard rootless-podman map. The script makes the map once, at the real level,
# where newuidmap holds its privilege. A nested user namespace cannot write a
# multi-line child map, so no lower level can make this map. bwrap then runs
# inside that user namespace, and it does not pass --unshare-user. podman reads
# _CONTAINERS_USERNS_CONFIGURED and treats the namespace as its own rootless
# namespace. Containers then run in the box namespace and read its subuid map.
# For the details, read the podman wrapper and the namespace section below.
set -euo pipefail

# The command to run inside the box. The default is an interactive shell.
if [ "$#" -gt 0 ]; then cmd=("$@"); else cmd=(bash); fi

# The box is already active, so do not nest a second one. Run the command.
if [ -n "${SANDBOXED:-}" ]; then
  exec "${cmd[@]}"
fi

if ! command -v bwrap >/dev/null 2>&1; then
  echo "sandbox: bwrap not found on PATH (is it in shell.nix buildInputs?)" >&2
  exit 1
fi

WORK_DIR="$(readlink -f .)"
UID_NUM="$(id -u)"

# The box's home is a tmpfs at the same path as the native home, so the native
# home never reaches the box. Two entries then land on that tmpfs, if the search
# below finds them: the .claude directory and the .claude.json file. A host
# layout keeps them under any one of three roots, so the search reads each root
# in turn and takes the first one that holds the entry. The box sees the same
# layout whatever the host has, because the destination path is always the same.
HOME_INSIDE="$HOME"

# first_root <test> <entry> => the first "<root>/<entry>" that passes <test>
# Example: first_root -d .claude      => /home/me/.local/share/Claude/.claude
# Example: first_root -f .claude.json => /home/me/.claude.json
# Example: first_root -d .absent      => "", and exit status 1
first_root() {
  local test="$1" entry="$2" root
  for root in "${HOME_ROOTS[@]}"; do
    [ -z "$root" ] && continue
    [ "$test" "$root/$entry" ] && printf '%s\n' "$root/$entry" && return 0
  done
  return 1
}

HOME_ROOTS=("${CLAUDE_DIR:-}" "$HOME/.local/share/Claude" "$HOME")
CLAUDE_DATA="$(first_root -d .claude || true)"
CLAUDE_STATE="$(first_root -f .claude.json || true)"

# The scratch directory holds the artifacts that only the sandbox uses: the
# podman config, the wrappers, and podman's storage. git ignores the directory,
# and each worktree has its own.
SANDBOX_DIR="$WORK_DIR/.sandbox"
mkdir -p "$SANDBOX_DIR/storage"

# --- The podman wrapper that injects the flags ---
# The sandbox alone uses this wrapper, and each entry writes it again.
# The box has no systemd and no dbus. The systemd defaults need a dbus socket,
# so the wrapper selects cgroupfs and file events instead. A nested box can also
# have no fuse, so the wrapper selects vfs instead of overlay. The
# ignore_chown_errors setting is a safety net, and it does no harm: the box user
# namespace maps the full subuid range, so an image-extraction chown normally
# succeeds. An image can still name a UID outside that range, and extraction
# then proceeds anyway. podman applies all of these settings reliably as CLI
# flags. It does not apply them reliably from containers.conf, so this script
# wraps podman and injects the flags. The storage lives under the project, which
# keeps each worktree separate, as the storage requirement asks. The runroot
# lives in the box's own /run tmpfs. Inside the box, PATH puts the wrapper first,
# as shell.nix arranges, so the docker shim and podman-compose both resolve
# podman to it.
mkdir -p "$SANDBOX_DIR/bin" "$SANDBOX_DIR/storage"
REAL_PODMAN="$(command -v podman)"
REAL_PODMAN_COMPOSE="$(command -v podman-compose)"
# These three values name the store's location and its driver, one time. The
# podman wrapper passes them as flags. The storage.conf file below states the
# same three values, for a podman that PATH does not resolve to the wrapper. The
# wrapper and storage.conf both read these three names, so the two cannot name
# different stores.
STORAGE_ROOT="$SANDBOX_DIR/storage"
STORAGE_RUNROOT="/run/user/$UID_NUM/containers"
if [ -e /dev/fuse ]; then STORAGE_DRIVER=overlay; else STORAGE_DRIVER=vfs; fi
cat > "$SANDBOX_DIR/bin/podman" <<EOF
#!/usr/bin/env bash
# enter-sandbox.sh generated this file. It injects the sandbox's podman settings.
# The global flags set these four things:
#   cgroupfs and file events, because the box has no systemd and no dbus
#   the storage driver
#   ignore_chown_errors, as a safety net
#   the per-worktree root and the box runroot
g=(--cgroup-manager=cgroupfs --events-backend=file \\
   --storage-driver=$STORAGE_DRIVER \\
   --storage-opt=$STORAGE_DRIVER.ignore_chown_errors=true \\
   --root="$STORAGE_ROOT" --runroot="$STORAGE_RUNROOT")
# The box has no writable /sys/fs/cgroup, so a container must run without a
# cgroup. The --cgroups=disabled flag does that. There is no --userns flag here.
# podman adopts the box's own user namespace as its rootless namespace, which the
# header and _CONTAINERS_USERNS_CONFIGURED describe. A container then runs in
# that namespace by default. A fixed image UID, such as postgres 999, tempo
# 10001, or prometheus 65534, is only a process UID inside that namespace. The
# subuid map resolves it, so the container starts.
case "\${1:-}" in
  run|create)
    sub="\$1"; shift
    exec "$REAL_PODMAN" "\${g[@]}" "\$sub" --cgroups=disabled "\$@" ;;
  *)
    exec "$REAL_PODMAN" "\${g[@]}" "\$@" ;;
esac
EOF
chmod +x "$SANDBOX_DIR/bin/podman"
# This file states the same store as configuration, for a podman that the wrapper
# never sees. The flags above apply only when PATH resolves podman to the
# wrapper. A caller that runs podman by absolute path therefore keeps the default
# store under $HOME. That caller then reads a different store from the one the
# containers live in, and it reports every container here as missing. Storage
# settings do apply from a file, unlike the cgroup and events settings above.
# CONTAINERS_STORAGE_CONF points every podman in the box at this file.
cat > "$SANDBOX_DIR/storage.conf" <<EOF
[storage]
driver = "$STORAGE_DRIVER"
graphroot = "$STORAGE_ROOT"
runroot = "$STORAGE_RUNROOT"

[storage.options.$STORAGE_DRIVER]
ignore_chown_errors = "true"
EOF
# A self-contained `docker` shim for the box. It sends `docker compose` to
# podman-compose, which resolves `podman` through PATH to the wrapper above. It
# sends every other command straight to the wrapper. This shim shadows the
# dockerShim from shell.nix inside the box, so the box does not depend on the
# form of that shim.
cat > "$SANDBOX_DIR/bin/docker" <<EOF
#!/usr/bin/env bash
# Generated by enter-sandbox.sh.
if [ "\$1" = compose ]; then
  shift
  exec "$REAL_PODMAN_COMPOSE" "\$@"
fi
exec "$SANDBOX_DIR/bin/podman" "\$@"
EOF
chmod +x "$SANDBOX_DIR/bin/docker"
# The box entrypoint. The box has no systemd, so nothing drives podman's
# healthcheck timers. This entrypoint starts a runner that drives them. Every few
# seconds, the runner calls `podman healthcheck run` for each running container
# that has a healthcheck and is not healthy yet. The entrypoint then execs the
# real command. `depends_on: service_healthy` then resolves exactly as it does
# under systemd on a normal machine, and the compose flow stays untouched. A
# pidfile guard keeps one runner per box. The runner dies with the sandbox.
cat > "$SANDBOX_DIR/bin/box-init" <<'EOF'
#!/usr/bin/env bash
_wrap="$(dirname "$(readlink -f "$0")")/podman"
# The wrapper flags and storage.conf must name one store. enter-sandbox.sh writes
# both from the same three values, so a mismatch here means that somebody edited
# one of them to hold a literal. This check warns and does not block. A podman
# that reads the wrong store still runs. It only reports every container here as
# missing.
_want_root="$(sed -n 's/^graphroot = "\(.*\)"$/\1/p' "$CONTAINERS_STORAGE_CONF" 2>/dev/null)"
_seen_root="$("$_wrap" info --format '{{.Store.GraphRoot}}' 2>/dev/null)"
if [ -n "$_want_root" ] && [ "$_seen_root" != "$_want_root" ]; then
  echo "sandbox: WARNING: storage root mismatch" >&2
  echo "sandbox: WARNING: podman reads    $_seen_root" >&2
  echo "sandbox: WARNING: storage.conf says $_want_root" >&2
fi
if [ ! -e "$XDG_RUNTIME_DIR/healthrun.pid" ]; then
  ( echo "$BASHPID" > "$XDG_RUNTIME_DIR/healthrun.pid"
    while :; do
      for _hc in $("$_wrap" ps -q 2>/dev/null); do
        # Call the healthcheck only for a container that has one and is not
        # healthy yet.
        _st="$("$_wrap" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$_hc" 2>/dev/null)"
        case "$_st" in
          "" | healthy) ;;
          *) "$_wrap" healthcheck run "$_hc" >/dev/null 2>&1 || true ;;
        esac
      done
      sleep 3
    done ) >/dev/null 2>&1 &
fi
exec "$@"
EOF
chmod +x "$SANDBOX_DIR/bin/box-init"

args=()

# --- Namespace isolation ---
# This script does not pass --unshare-all. That option includes --unshare-user,
# which would make bwrap's own user namespace with a single UID in it. It would
# also discard the subuid-mapped namespace that `unshare` builds below. So the
# script unshares everything else, and it keeps the network shared. A shared
# network lets the host reach a published container port, as it does on a normal
# machine. bwrap runs as root inside the box user namespace, so it holds the
# capabilities to set up these namespaces and to mount.
args+=(--unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup --die-with-parent)

# --- System directories (read-only) ---
for dir in /usr /etc; do
  [ -d "$dir" ] && args+=(--ro-bind "$dir" "$dir")
done
# On some systems, /bin, /sbin, /lib, and /lib64 are real directories. On other
# systems, they are symlinks into /usr. This loop makes a read-only bind for the
# first case and a symlink for the second case.
for dir in /bin /sbin /lib /lib64; do
  if [ -L "$dir" ]; then
    args+=(--symlink "$(readlink "$dir")" "$dir")
  elif [ -d "$dir" ]; then
    args+=(--ro-bind "$dir" "$dir")
  fi
done

# podman looks for its rootless pause process, `catatonit -P`, at two hardcoded
# paths: /usr/bin/catatonit and /usr/libexec/podman/catatonit. It does not read
# helper_binaries_dir. /usr is read-only, so this script puts an overlay on
# /usr/bin, which keeps the real contents, and then binds catatonit at the path
# podman reads. shell.nix supplies SANDBOX_CATATONIT as a nix store path, so this
# script scans no store.
if [ -n "${SANDBOX_CATATONIT:-}" ] && [ -e "$SANDBOX_CATATONIT" ]; then
  args+=(--overlay-src /usr/bin --tmp-overlay /usr/bin --ro-bind "$SANDBOX_CATATONIT" /usr/bin/catatonit)
fi

# --- Nix store + NixOS system profile (read-only) ---
[ -d /nix ] && args+=(--ro-bind /nix /nix)
[ -d /run/current-system ] && args+=(--ro-bind /run/current-system /run/current-system)

# --- Virtual filesystems ---
# Bind the host's real /dev, not bwrap's synthetic `--dev /dev`. A buildah RUN
# step binds /dev recursively and then remounts it read-only. The kernel denies
# that remount when /dev holds locked read-write submounts. A synthetic /dev
# holds exactly that, because each device node is a separate bind mount. A real
# devtmpfs holds its nodes as files, not as submounts, so the remount succeeds.
# This is the same reason a build works on a normal machine. The user namespace
# still bounds the access: root inside the box is not real root, so it cannot
# open a node that a normal non-root user cannot open. The real /dev also
# supplies /dev/fuse for overlay and /dev/net/tun for pasta.
# Each sandbox still gets its own /run tmpfs, so podman's runroot stays private
# to the instance.
args+=(--proc /proc --dev-bind /dev /dev --tmpfs /tmp --tmpfs /run)

# The XDG runtime directory must exist for podman. podman fails without it.
args+=(--dir "/run/user/$UID_NUM")

# --- Podman enablers ---
# This script does not mask /etc/subuid and /etc/subgid. They arrive through the
# read-only bind of /etc. The namespace section below builds the box user
# namespace from them, on the host. podman then treats the box user namespace as
# its own configured rootless namespace. A read-only /sys improves how podman
# detects the cgroups and the host, and it also stops a `podman info` crash.
[ -d /sys ] && args+=(--ro-bind /sys /sys)

# --- Writable mounts: the box's home and the project (only) ---
# The tmpfs comes first, so the two entries below land on top of it. The .claude
# directory is a read-write bind. The .claude.json file is a copy: bwrap reads
# the host file through file descriptor 9 and writes a real file on the tmpfs. A
# save that replaces the file by rename then works. The host file cannot change,
# and the box loses every write to the copy at exit.
args+=(--tmpfs "$HOME_INSIDE")
[ -n "$CLAUDE_DATA" ] && args+=(--bind "$CLAUDE_DATA" "$HOME_INSIDE/.claude")
if [ -n "$CLAUDE_STATE" ]; then
  exec 9<"$CLAUDE_STATE"
  args+=(--perms 0600 --file 9 "$HOME_INSIDE/.claude.json")
fi
args+=(--bind "$WORK_DIR" "$WORK_DIR")
args+=(--chdir "$WORK_DIR")

# podman looks for policy.json under $HOME/.config/containers. That file holds
# the signature trust. registries.conf resolves to the same directory, because
# XDG_CONFIG_HOME defaults to $HOME/.config. That file holds the docker.io
# short-name resolution. So this script binds the repo's config directory there.
# /etc/containers cannot hold them: it is absent, and /etc is read-only. This
# bind comes after the home mount, so the mountpoint lands inside it.
[ -d "$WORK_DIR/.config/containers" ] \
  && args+=(--ro-bind "$WORK_DIR/.config/containers" "$HOME_INSIDE/.config/containers")

# --- Git worktree support ---
# In a worktree, $WORK_DIR/.git is a file, not a directory. The file holds
# "gitdir: <path>". The path points at the real gitdir. That gitdir lives under
# the main repo, outside $WORK_DIR. The shared common directory holds objects,
# refs, and config. The code below binds the gitdir and the common directory. It
# then puts a tmpfs on the common directory's worktrees/, so the sandbox cannot
# reach a sibling worktree.
if [ -f "$WORK_DIR/.git" ]; then
  GIT_DIR="$(sed -n 's/^gitdir: //p' "$WORK_DIR/.git" | head -n1)"
  if [ -n "$GIT_DIR" ] && [[ "$GIT_DIR" != /* ]]; then
    GIT_DIR="$WORK_DIR/$GIT_DIR"
  fi
  GIT_DIR="$(readlink -f "$GIT_DIR" 2>/dev/null || true)"
  if [ -n "$GIT_DIR" ] && [ -d "$GIT_DIR" ]; then
    if [ -f "$GIT_DIR/commondir" ]; then
      COMMON_DIR="$(cat "$GIT_DIR/commondir")"
      [[ "$COMMON_DIR" != /* ]] && COMMON_DIR="$GIT_DIR/$COMMON_DIR"
      COMMON_DIR="$(readlink -f "$COMMON_DIR")"
    else
      COMMON_DIR="$GIT_DIR"
    fi
    args+=(--bind "$COMMON_DIR" "$COMMON_DIR")
    [ -d "$COMMON_DIR/worktrees" ] && args+=(--tmpfs "$COMMON_DIR/worktrees")
    args+=(--bind "$GIT_DIR" "$GIT_DIR")
  fi
fi

# --- Environment inside the box ---
args+=(--setenv SANDBOXED 1)
args+=(--setenv HOME "$HOME_INSIDE")
args+=(--setenv XDG_RUNTIME_DIR "/run/user/$UID_NUM")
# Reset TMPDIR. The outer nix develop points it at /run/user/.../nix-shell.XXX.
# That path does not exist in the box's fresh /run tmpfs, and podman needs a
# valid TMPDIR.
args+=(--setenv TMPDIR /tmp)
args+=(--setenv TERM "${TERM:-xterm-256color}")
# The box has no /sys/fs/cgroup, so podman detects cgroups v1 in error. This
# variable silences the warning.
args+=(--setenv PODMAN_IGNORE_CGROUPSV1_WARNING 1)
# Every podman in the box reads the sandbox store. This includes a podman that
# PATH does not resolve to the wrapper. The storage.conf file beside the wrapper
# makes that work.
args+=(--setenv CONTAINERS_STORAGE_CONF "$SANDBOX_DIR/storage.conf")
# We enter as root inside the box's subuid-mapped user namespace, which `unshare
# --map-root-user` built. These three variables tell podman that it is already in
# its rootless namespace. _CONTAINERS_ROOTLESS_UID and _CONTAINERS_ROOTLESS_GID
# keep podman in rootless mode, although its euid is 0.
# _CONTAINERS_USERNS_CONFIGURED makes podman skip the startup reexec. That reexec
# would otherwise try to build a fresh namespace through newuidmap, which a
# nested namespace cannot do. `podman unshare` uses this same handshake for a
# nested podman. Containers then run in the box user namespace and see its subuid
# map. That is the point of the multi-UID support.
args+=(--setenv _CONTAINERS_USERNS_CONFIGURED done)
args+=(--setenv _CONTAINERS_ROOTLESS_UID "$UID_NUM")
args+=(--setenv _CONTAINERS_ROOTLESS_GID "$(id -g)")
# This matches .envrc, so a `nix develop` run inside the box evaluates the flake
# the same way.
args+=(--setenv NIXPKGS_ALLOW_INSECURE 1)
# Pass the Claude API credentials through, if the host sets them. A `claude` run
# in the box then works in auto mode.
for var in ANTHROPIC_API_KEY CLAUDE_API_KEY; do
  [ -n "${!var:-}" ] && args+=(--setenv "$var" "${!var}")
done

# --- Build the box's user namespace, then run bwrap in it ---
# bwrap must not create the user namespace, because --unshare-user gives it a
# single UID. `unshare` builds the standard rootless map instead, with the host's
# setuid newuidmap and newgidmap. The --map-root-user flag puts our UID at inner
# 0, which is root in the box. The --map-auto flag maps our whole /etc/subuid and
# /etc/subgid range to the inner IDs that the first flag leaves free, 1 to N.
# Every UID that a container runs as is therefore a mapped inner ID, such as 0,
# 999, 10001, and 65534. bwrap and podman both run inside this namespace. podman
# would build this same map for itself on a normal host. This script builds it at
# the one level where newuidmap holds its privilege, because a nested namespace
# cannot write a multi-line map.
if ! grep -Eq "^($(id -un)|$(id -u)):" /etc/subuid 2>/dev/null; then
  echo "sandbox: no /etc/subuid range for $(id -un): rootless podman needs a delegated subid range" >&2
  exit 1
fi

exec unshare --user --map-root-user --map-auto \
  -- bwrap "${args[@]}" -- "$SANDBOX_DIR/bin/box-init" "${cmd[@]}"
