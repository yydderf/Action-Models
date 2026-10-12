#!/usr/bin/env bash
#
# bootstrap-models-dir.sh — establish and re-converge the shared model store.
#
# Policy enforced:
#   * every entry is owned  root:models
#   * directories are 2755  (setgid, so new entries inherit the group)
#   * regular files are 0644 (0755 if already executable)
#   * => root writes, everyone reads.  No non-root user can add, replace or
#        delete a weight file, which is what keeps the store consistent while
#        HF_HUB_OFFLINE=1 stops clients from silently re-resolving it.
#   * named secrets (the HF tokens) are forced back to 0600.
#
# Run it to create the store, and again after every root-side download:
# `hf download` honours root's umask and has been observed emitting 0600
# files into trees/, which then read as missing to everyone else.
#
# Note on ACLs: a default ACL cannot fix that.  Default ACLs are an upper
# bound on inherited permissions (like umask), so they never widen a file the
# creating process explicitly opened as 0600.  Only a normalising pass does.
# Hence this script, rather than setfacl -d.
#
# Dry-run by default; pass --apply to commit.

set -euo pipefail

GROUP="models"
ROOT="/srv/models"
HF_HOME_DIR="$ROOT/huggingface"

# Files that must stay root-only, relative to $HF_HOME_DIR.
SECRETS=("token" "stored_tokens")

APPLY=0
GROUP_WRITABLE=0
WRITABLE_MODULES=0
GROUP_GID=""
declare -a ADD_USERS=()

usage() {
    cat <<'USAGE'
Usage: bootstrap-models-dir.sh [options]

  --apply              Make changes. Without it, only report drift.
  --root DIR           Store root (default: /srv/models).
  --group NAME         Group name (default: models).
  --gid N              GID to use if the group must be created.
  --add-user USER      Add USER to the group. Repeatable.
  --group-writable     Directories 2775 instead of 2755, letting group
                       members curate the store. Off by default: the stated
                       policy is that only root modifies weights.
  --writable-modules   Leave huggingface/modules world-writable. Off by
                       default; prefer a per-user HF_MODULES_CACHE.
  -h, --help           This text.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)            APPLY=1 ;;
        --root)             ROOT="$2"; HF_HOME_DIR="$ROOT/huggingface"; shift ;;
        --group)            GROUP="$2"; shift ;;
        --gid)              GROUP_GID="$2"; shift ;;
        --add-user)         ADD_USERS+=("$2"); shift ;;
        --group-writable)   GROUP_WRITABLE=1 ;;
        --writable-modules) WRITABLE_MODULES=1 ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

DIR_MODE=2755
[[ $GROUP_WRITABLE -eq 1 ]] && DIR_MODE=2775

CHANGES=0

say()  { printf '%s\n' "$*"; }
head2() { printf '\n== %s\n' "$*"; }

# Run a mutating command, or describe it.
act() {
    CHANGES=$((CHANGES + 1))
    if [[ $APPLY -eq 1 ]]; then
        say "  [do]   $*"
        "$@"
    else
        say "  [plan] $*"
    fi
}

if [[ $APPLY -eq 1 && $EUID -ne 0 ]]; then
    echo "--apply needs root (try: sudo $0 --apply ...)" >&2
    exit 1
fi

[[ $APPLY -eq 1 ]] || say "DRY RUN — nothing will be changed. Re-run with --apply."

# ---------------------------------------------------------------- group
head2 "group '$GROUP'"
if getent group "$GROUP" >/dev/null; then
    say "  present: $(getent group "$GROUP")"
else
    if [[ -n "$GROUP_GID" ]]; then
        act groupadd --gid "$GROUP_GID" "$GROUP"
    else
        act groupadd "$GROUP"
    fi
fi

for u in ${ADD_USERS+"${ADD_USERS[@]}"}; do
    if ! getent passwd "$u" >/dev/null; then
        say "  !! no such user: $u — skipping"
        continue
    fi
    if id -nG "$u" | tr ' ' '\n' | grep -qx "$GROUP"; then
        say "  $u already in $GROUP"
    else
        act gpasswd --add "$u" "$GROUP"
    fi
done

# ------------------------------------------------------------ structure
head2 "directory structure"
for d in "$ROOT" "$HF_HOME_DIR" "$HF_HOME_DIR/hub" "$HF_HOME_DIR/xet" "$HF_HOME_DIR/modules"; do
    if [[ -d "$d" ]]; then
        say "  exists: $d"
    else
        act mkdir -p "$d"
    fi
done

if [[ ! -d "$ROOT" ]]; then
    say "  (store does not exist yet; re-run with --apply, then again to normalise)"
    exit 0
fi

# ------------------------------------------------------------ ownership
head2 "ownership -> root:$GROUP"
mapfile -d '' -t WRONG_OWN < <(find "$ROOT" \( ! -user root -o ! -group "$GROUP" \) -print0 2>/dev/null)
if [[ ${#WRONG_OWN[@]} -eq 0 ]]; then
    say "  all ${ROOT} entries already root:$GROUP"
else
    say "  ${#WRONG_OWN[@]} entry/entries with wrong owner or group, e.g.:"
    for p in "${WRONG_OWN[@]:0:5}"; do say "    $(stat -c '%U:%G %a %n' "$p")"; done
    act chown -h -R "root:$GROUP" "$ROOT"
fi

# ----------------------------------------------------------- dir modes
head2 "directory modes -> $DIR_MODE"
SKIP_MODULES=()
if [[ $WRITABLE_MODULES -eq 1 && -d "$HF_HOME_DIR/modules" ]]; then
    SKIP_MODULES=(-path "$HF_HOME_DIR/modules" -prune -o)
    say "  (leaving $HF_HOME_DIR/modules as-is per --writable-modules)"
fi

mapfile -d '' -t WRONG_DIR < <(
    find "$ROOT" ${SKIP_MODULES+"${SKIP_MODULES[@]}"} -type d ! -perm "$DIR_MODE" -print0 2>/dev/null
)
if [[ ${#WRONG_DIR[@]} -eq 0 ]]; then
    say "  all directories already $DIR_MODE"
else
    say "  ${#WRONG_DIR[@]} directory/directories to normalise, e.g.:"
    for p in "${WRONG_DIR[@]:0:8}"; do say "    $(stat -c '%a %n' "$p")"; done
    if [[ $APPLY -eq 1 ]]; then
        CHANGES=$((CHANGES + 1))
        say "  [do]   chmod $DIR_MODE on ${#WRONG_DIR[@]} directories"
        printf '%s\0' "${WRONG_DIR[@]}" | xargs -0 -r chmod "$DIR_MODE"
    else
        CHANGES=$((CHANGES + 1))
        say "  [plan] chmod $DIR_MODE on ${#WRONG_DIR[@]} directories"
    fi
fi

# ---------------------------------------------------------- file modes
# Wrong = writable by group/other, or not readable by both.
head2 "file modes -> 0644 (0755 if executable)"
mapfile -d '' -t WRONG_FILE < <(
    find "$ROOT" ${SKIP_MODULES+"${SKIP_MODULES[@]}"} -type f \
        \( -perm /022 -o ! -perm -044 \) -print0 2>/dev/null
)

# Drop the secrets; they are handled separately and must not be widened.
declare -a FIX_FILE=()
for p in ${WRONG_FILE+"${WRONG_FILE[@]}"}; do
    skip=0
    for s in "${SECRETS[@]}"; do
        [[ "$p" == "$HF_HOME_DIR/$s" ]] && skip=1
    done
    [[ $skip -eq 0 ]] && FIX_FILE+=("$p")
done

if [[ ${#FIX_FILE[@]} -eq 0 ]]; then
    say "  all files already root-writable / world-readable"
else
    say "  ${#FIX_FILE[@]} file(s) to normalise, e.g.:"
    for p in "${FIX_FILE[@]:0:8}"; do say "    $(stat -c '%a %n' "$p")"; done
    if [[ $APPLY -eq 1 ]]; then
        CHANGES=$((CHANGES + 1))
        say "  [do]   chmod u=rwX,g=rX,o=rX on ${#FIX_FILE[@]} files"
        printf '%s\0' "${FIX_FILE[@]}" | xargs -0 -r chmod u=rwX,g=rX,o=rX
    else
        CHANGES=$((CHANGES + 1))
        say "  [plan] chmod u=rwX,g=rX,o=rX on ${#FIX_FILE[@]} files"
    fi
fi

# ------------------------------------------------------------- secrets
head2 "secrets -> 0600 root-only"
for s in "${SECRETS[@]}"; do
    f="$HF_HOME_DIR/$s"
    [[ -f "$f" ]] || { say "  absent: $f"; continue; }
    mode=$(stat -c '%a' "$f")
    if [[ "$mode" == "600" ]]; then
        say "  ok: $f ($mode)"
    else
        say "  !! $f is $mode — root's HF token is exposed to other users"
        act chmod 600 "$f"
    fi
done

# -------------------------------------------------------------- report
head2 "summary"
if [[ $CHANGES -eq 0 ]]; then
    say "  store already matches policy; nothing to do."
elif [[ $APPLY -eq 1 ]]; then
    say "  applied $CHANGES change group(s)."
else
    say "  $CHANGES change group(s) pending. Re-run with --apply."
fi

cat <<NOTES

Client environment for the shared store (read-only consumers):

  export HF_HOME=$HF_HOME_DIR
  export HF_HUB_OFFLINE=1
  export HF_MODULES_CACHE="\$HOME/.cache/huggingface/modules"

The last line matters: transformers writes trust_remote_code modules into
HF_MODULES_CACHE at import time. Pointing it at the shared tree is why
modules/ ended up world-writable. Giving each user their own keeps the
shared store read-only without breaking custom-code models.

To refresh weights, as root:

  HF_HOME=$HF_HOME_DIR HF_HUB_OFFLINE=0 hf download <repo> --revision <sha>
  sudo $0 --apply
NOTES
