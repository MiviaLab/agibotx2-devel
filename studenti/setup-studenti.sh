#!/bin/bash
# Set up (or restore after a firmware update) the student container.
# Run as agi with sudo:   sudo bash ~/aimdk-image/studenti/setup-studenti.sh [options]
#
# Options:
#   --password       set/change the SSH password of "studente"
#   --rebuild        rebuild the student image and recreate the container
#                    (discards packages installed with apt inside the container)
#   --recreate       recreate the container from the existing image (after changing
#                    run-studenti.sh; discards packages installed with apt)
#   --refresh-msgs   re-sync aimdk/src/aimdk_msgs of the students' repository from ~/aimdk
#                    (after an SDK/firmware update; the students' own code is untouched)
# Env: SSH_PORT (default 2222), STUDENTS_REPO (git URL cloned if the repository is missing)
#
# Idempotent: safe to run again. What it does:
#   1. host user "studenti" (UID 1101): no sudo, password locked, no shell, SSH login denied
#   2. /etc/subuid, /etc/subgid entries for rootless podman (+ device groups)
#   3. /home/agi: "others" may traverse it (o+x) but not list it; agi's top-level
#      entries lose "others" permissions so studenti cannot read them
#   4. /home/agi/studenti (persistent across firmware updates): config, keys, the
#      agibotx2-students repository (= students' home, with the SDK copy) and a
#      copy of the firmware messages + robot URDF for Foxglove
#   5. image agi/aimdk-studenti:dev (from agi/aimdk-dev:dev), container aimdk-studenti,
#      autostart at boot (linger + podman-restart.service)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
U=studenti
UID_S=1101
AGI=agi
AGI_HOME=/home/agi
BASE=$AGI_HOME/studenti
SDK_SRC=$AGI_HOME/aimdk
STUD_HOME=$BASE/agibotx2-students
STUDENTS_REPO="${STUDENTS_REPO:-https://github.com/MiviaLab/agibotx2-students.git}"
FW_COMMON=/agibot/software/common
FW_URDF=/agibot/software/aimdk/extra/mc-rl/x2_urdf/X2_URDF-v1.3.0
SUB_START=231072
SUB_COUNT=65536
DEV_GROUPS=(dialout audio video input render)
DEV_GIDS=(20 29 44 106 109)
SSH_PORT="${SSH_PORT:-2222}"
IMAGE_BASE=agi/aimdk-dev:dev
IMAGE_STUD=agi/aimdk-studenti:dev
CONTAINER=aimdk-studenti

OPT_PASSWORD=0; OPT_REBUILD=0; OPT_REFRESH=0; OPT_RECREATE=0
for a in "$@"; do
  case "$a" in
    --recreate) OPT_RECREATE=1 ;;
    --password) OPT_PASSWORD=1 ;;
    --rebuild) OPT_REBUILD=1 ;;
    --refresh-msgs) OPT_REFRESH=1 ;;
    *) echo "Unknown option: $a" >&2; exit 1 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }
as_agi() {
  ( cd "$AGI_HOME" && runuser -u "$AGI" -- env XDG_RUNTIME_DIR="/run/user/$(id -u $AGI)" HOME="$AGI_HOME" "$@" )
}
as_stud() {
  ( cd "$BASE" && runuser -u "$U" -- env XDG_RUNTIME_DIR="/run/user/$UID_S" HOME="$BASE" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_S/bus" "$@" )
}

# ---------------------------------------------------------------- 1. user
say "1. Host user $U"
getent group "$U" >/dev/null || groupadd -g "$UID_S" "$U"
if ! id "$U" >/dev/null 2>&1; then
  useradd -u "$UID_S" -g "$UID_S" -d "$BASE" -M -s /usr/sbin/nologin -c "Student container owner" "$U"
fi
[ "$(id -u "$U")" = "$UID_S" ] || { echo "User $U exists with a different UID, aborting" >&2; exit 1; }
usermod -d "$BASE" -s /usr/sbin/nologin -G "$(IFS=,; echo "${DEV_GROUPS[*]}")" "$U"
passwd -l "$U" >/dev/null
if id -nG "$U" | tr ' ' '\n' | grep -qxE 'sudo|admin|docker|netdev|agi|run|manager|adm'; then
  echo "User $U is in a privileged group, aborting" >&2; exit 1
fi
echo "   $(id "$U")"

# ---------------------------------------------------------------- 2. subuid/subgid
say "2. /etc/subuid and /etc/subgid"
sed -i 's/[[:space:]]*$//' /etc/subuid /etc/subgid   # trailing spaces break the parser (see guide)
# The range must not overlap any other user's range.
for f in /etc/subuid /etc/subgid; do
  awk -F: -v u="$U" -v s="$SUB_START" -v c="$SUB_COUNT" \
    '$1!=u && $3>1 && $2<s+c && $2+$3>s {print "overlap in " FILENAME ": " $0; bad=1} END{exit bad}' "$f" \
    || { echo "Choose a different SUB_START, aborting" >&2; exit 1; }
done
add_line() { grep -qxF "$2" "$1" || echo "$2" >> "$1"; }
add_line /etc/subuid "$U:$SUB_START:$SUB_COUNT"
add_line /etc/subgid "$U:$SUB_START:$SUB_COUNT"
for g in "${DEV_GIDS[@]}"; do add_line /etc/subgid "$U:$g:1"; done
grep "^$U:" /etc/subuid /etc/subgid | sed 's/^/   /'

# ---------------------------------------------------------------- 3. /home/agi permissions
say "3. Permissions of $AGI_HOME"
chmod o+x "$AGI_HOME"
while IFS= read -r -d '' e; do
  [ "$e" = "$BASE" ] && continue
  if [ -n "$(find "$e" -maxdepth 0 -perm /o=rwx)" ]; then
    chmod o-rwx "$e"; echo "   o-rwx $e"
  fi
done < <(find "$AGI_HOME" -mindepth 1 -maxdepth 1 ! -type l -user "$AGI" -print0)
stat -c '   %A %U:%G %n' "$AGI_HOME"

# ---------------------------------------------------------------- 4. directories, config
say "4. $BASE"
mkdir -p "$BASE"/{config,secrets,sshd-keys,bin,build,firmware}
chown "$U:$AGI" "$BASE"; chmod 750 "$BASE"           # agi (group) can look inside
chown -R "$U:$U" "$BASE"/{config,secrets,sshd-keys,bin,build}
chmod 700 "$BASE"/{secrets,sshd-keys}

AIMA_ENV=$AGI_HOME/.aima/env
if [ -r "$AIMA_ENV/ros_dds_configuration.xml" ]; then
  install -o "$U" -g "$U" -m 644 "$AIMA_ENV/ros_dds_configuration.xml" "$BASE/config/ros_dds_configuration.xml"
fi
if [ -r "$AIMA_ENV/bashrc" ]; then
  sed -nE "s/^export (AGIBOT_[A-Z_]+)='(.*)'\$/\1=\2/p" "$AIMA_ENV/bashrc" > "$BASE/config/agibot.env"
  chown "$U:$U" "$BASE/config/agibot.env"; chmod 644 "$BASE/config/agibot.env"
fi
for f in Dockerfile.studenti sshd-studenti.conf entrypoint-studenti.sh; do
  install -o "$U" -g "$U" -m 644 "$HERE/$f" "$BASE/build/$f"
done
install -o "$U" -g "$U" -m 755 "$HERE/run-studenti.sh" "$BASE/bin/run-studenti.sh"

# ---------------------------------------------------------------- students' repository (home)
if [ ! -d "$STUD_HOME/aimdk" ]; then
  say "   Cloning $STUDENTS_REPO into $STUD_HOME"
  git clone "$STUDENTS_REPO" "$STUD_HOME"
fi
# The AgiBot HTML docs are not versioned (too big): copy them from the robot's SDK.
if [ ! -d "$STUD_HOME/aimdk/docs" ] && [ -d "$SDK_SRC/docs" ]; then
  say "   Copying the SDK documentation to $STUD_HOME/aimdk/docs"
  rsync -a "$SDK_SRC/docs/" "$STUD_HOME/aimdk/docs/"
fi
if [ "$OPT_REFRESH" -eq 1 ]; then
  say "   Re-syncing src/aimdk_msgs and version from $SDK_SRC"
  rsync -a --delete "$SDK_SRC/src/aimdk_msgs/" "$STUD_HOME/aimdk/src/aimdk_msgs/"
  cp "$SDK_SRC/version" "$STUD_HOME/aimdk/version"
  echo "   Students must rebuild: rm -rf ~/aimdk/build/aimdk_msgs ~/aimdk/install/aimdk_msgs && colcon build"
fi

# ---------------------------------------------------------------- firmware files for Foxglove
# The container cannot read /agibot/software (root:manager 750): copy the firmware
# aimdk_msgs (more complete than the public SDK) and the robot URDF + meshes.
# run-studenti.sh mounts them read-only in /opt/agibot. Refreshed at every run,
# so after a firmware update it is enough to run this script again.
say "   Copying firmware messages and URDF to $BASE/firmware"
R=share/ament_index/resource_index
F=$BASE/firmware/aimdk_msgs
if [ -d "$FW_COMMON/share/aimdk_msgs" ]; then
  rm -rf "$F"
  mkdir -p "$F/lib" "$F/share" "$F/$R/packages" "$F/$R/rosidl_interfaces"
  cp -r "$FW_COMMON/share/aimdk_msgs" "$F/share/aimdk_msgs"
  cp "$FW_COMMON/$R/packages/aimdk_msgs" "$F/$R/packages/"
  cp "$FW_COMMON/$R/rosidl_interfaces/aimdk_msgs" "$F/$R/rosidl_interfaces/"
  cp -L "$FW_COMMON"/lib/libaimdk_msgs__* "$F/lib/"
  echo "   $(ls "$F/share/aimdk_msgs/msg" | wc -l) firmware messages"
else
  echo "   WARNING: $FW_COMMON/share/aimdk_msgs not found, Foxglove will miss firmware messages" >&2
fi
if [ -f "$FW_URDF/x2_ultra.urdf" ]; then
  mkdir -p "$BASE/firmware/x2_urdf"
  rsync -a --delete --include=/x2_ultra.urdf --include=/meshes/ --include='/meshes/**' --exclude='*' \
        "$FW_URDF/" "$BASE/firmware/x2_urdf/"
else
  echo "   WARNING: $FW_URDF/x2_ultra.urdf not found, no 3D model in Foxglove" >&2
fi
chown -R "$U:$U" "$BASE/firmware"; chmod -R a+rX "$BASE/firmware"

# ---------------------------------------------------------------- password
if [ ! -s "$BASE/secrets/studente.hash" ] || [ "$OPT_PASSWORD" -eq 1 ]; then
  say "   SSH password for user 'studente' (what the students will type)"
  while :; do
    read -rsp "   New password: " p1; echo
    read -rsp "   Repeat:       " p2; echo
    [ -n "$p1" ] && [ "$p1" = "$p2" ] && break
    echo "   Empty or not matching, try again"
  done
  printf '%s' "$p1" | openssl passwd -6 -stdin > "$BASE/secrets/studente.hash"
  unset p1 p2
  chown "$U:$U" "$BASE/secrets/studente.hash"; chmod 600 "$BASE/secrets/studente.hash"
  PASSWORD_CHANGED=1
else
  PASSWORD_CHANGED=0
fi

# ---------------------------------------------------------------- host sshd: deny studenti
say "   Host SSH: login as $U denied"
SSHD_DROP=/etc/ssh/sshd_config.d/50-studenti.conf
cat > "$SSHD_DROP" <<EOF
# The host user studenti only owns the student container: no SSH login on the host.
Match User $U
    PasswordAuthentication no
    PubkeyAuthentication no
    KbdInteractiveAuthentication no
EOF
if sshd -t; then
  systemctl reload ssh
else
  rm -f "$SSHD_DROP"; echo "sshd config test failed, removed $SSHD_DROP" >&2; exit 1
fi

# ---------------------------------------------------------------- 5. linger, podman
say "5. Rootless podman for $U"
loginctl enable-linger "$U"
for _ in $(seq 1 30); do [ -S "/run/user/$UID_S/bus" ] && break; sleep 1; done
[ -d "/run/user/$UID_S" ] || { echo "/run/user/$UID_S not created, aborting" >&2; exit 1; }
as_stud podman system migrate >/dev/null 2>&1 || true

# Home of "studente" (container UID 1000) must be owned by that UID as seen by podman.
# Note: on the host the repository then belongs to a subordinate UID; use git from
# inside the container (as studente) or with sudo.
chown -R "$U:$U" "$STUD_HOME"
as_stud podman unshare chown -R 1000:1000 "$STUD_HOME"
chmod 755 "$STUD_HOME"

# SSH host keys of the container: generated here (keeping existing ones) and mounted
# read-only, so nobody inside the container (not even with sudo) can change them.
for t in ed25519 rsa; do
  k="$BASE/sshd-keys/ssh_host_${t}_key"
  [ -f "$k" ] || as_stud ssh-keygen -q -t "$t" -N '' -C "aimdk-studenti" -f "$k"
done

NEED_RUN=0
if [ "$OPT_REBUILD" -eq 1 ] || ! as_stud podman image exists "$IMAGE_STUD"; then
  as_agi podman image exists "$IMAGE_BASE" || {
    echo "Image $IMAGE_BASE not found for agi: build it first (cd ~/aimdk-image && podman build -t $IMAGE_BASE .)" >&2
    exit 1; }
  ID_AGI=$(as_agi podman image inspect --format '{{.Id}}' "$IMAGE_BASE")
  ID_STUD=$(as_stud podman image inspect --format '{{.Id}}' "$IMAGE_BASE" 2>/dev/null || true)
  if [ "$ID_AGI" = "$ID_STUD" ]; then
    say "   $IMAGE_BASE already up to date for $U, not copied"
  else
    say "   Copying $IMAGE_BASE from agi to $U (a few minutes)"
    # Via a file, not a pipe: "podman save | podman load" across users hung once.
    XFER=$(mktemp -d /var/tmp/aimdk-xfer.XXXXXX)
    chmod 755 "$XFER"
    as_agi podman save -o "$XFER/base.tar" "$IMAGE_BASE"
    chmod 644 "$XFER/base.tar"
    as_stud podman load -i "$XFER/base.tar"
    rm -rf "$XFER"
  fi
  say "   Building $IMAGE_STUD"
  as_stud podman build -t "$IMAGE_STUD" -f "$BASE/build/Dockerfile.studenti" "$BASE/build"
  NEED_RUN=1
fi
as_stud podman container exists "$CONTAINER" || NEED_RUN=1
[ "$OPT_RECREATE" -eq 1 ] && NEED_RUN=1

if [ "$NEED_RUN" -eq 1 ]; then
  say "   Creating container $CONTAINER"
  as_stud env SSH_PORT="$SSH_PORT" bash "$BASE/bin/run-studenti.sh"
else
  as_stud podman start "$CONTAINER" >/dev/null
  if [ "$PASSWORD_CHANGED" -eq 1 ]; then as_stud podman restart "$CONTAINER" >/dev/null; fi
fi

# The firmware resets /home/agi to 750 at every boot (agibot_mount.service,
# agibot/mount/050-mount_user.sh): re-add o+x before the studenti user manager
# starts, otherwise it cannot read its config and the container does not start.
say "   Boot hook: chmod o+x $AGI_HOME before user@$UID_S.service"
DROPIN_DIR=/etc/systemd/system/user@$UID_S.service.d
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_DIR/10-home-traverse.conf" <<EOF
# Created by setup-studenti.sh: see comment there.
[Unit]
After=agibot_mount.service
[Service]
ExecStartPre=+/bin/chmod o+x $AGI_HOME
EOF
systemctl daemon-reload

# Start containers with restart=always at boot (user service of studenti, kept in $BASE).
WANTS="$BASE/.config/systemd/user/default.target.wants"
mkdir -p "$WANTS"
ln -sf /usr/lib/systemd/user/podman-restart.service "$WANTS/podman-restart.service"
chown -R "$U:$U" "$BASE/.config"

# ---------------------------------------------------------------- summary
say "Done"
sleep 2
if ss -tlnH | awk '{print $4}' | grep -qE ":$SSH_PORT\$"; then
  echo "   sshd listening on port $SSH_PORT"
else
  echo "   WARNING: nothing listening on port $SSH_PORT, check: sudo -u $U XDG_RUNTIME_DIR=/run/user/$UID_S podman logs $CONTAINER"
fi
for ifc in wifi0 develop0; do
  ip -4 -o addr show "$ifc" 2>/dev/null | awk -v p="$SSH_PORT" '{split($4,a,"/"); print "   ssh -p " p " studente@" a[1] "   (" $2 ")"}'
done
