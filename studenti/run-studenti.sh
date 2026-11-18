#!/bin/bash
# Create the student container. Same options as AgiBot's run.sh, except:
#   - runs as host user "studenti" (container root = studenti, no sudo on host)
#   - home /home/studente = /home/agi/studenti/agibotx2-students (the students'
#     repository, with the SDK copy ~/aimdk, ~/foxglove and the guides)
#   - firmware messages and URDF (copied by setup-studenti.sh) read-only in /opt/agibot
#   - main process is sshd (port SSH_PORT), restart policy "always"
# WARNING: recreating the container discards packages installed with apt.
# Normally launched by setup-studenti.sh; by hand (as agi):
#   sudo -u studenti XDG_RUNTIME_DIR=/run/user/$(id -u studenti) bash /home/agi/studenti/bin/run-studenti.sh
set -euo pipefail

[ "$(id -un)" = "studenti" ] || { echo "Must run as user studenti" >&2; exit 1; }
cd "$HOME"

IMAGE="${IMAGE:-agi/aimdk-studenti:dev}"
NAME="${NAME:-aimdk-studenti}"
SSH_PORT="${SSH_PORT:-2222}"
BASE="/home/agi/studenti"
STUD_HOME="${STUD_HOME:-$BASE/agibotx2-students}"

MOUNTS=()
m() {
  local src="$1" dst="$2" opts="${3:-ro}"
  if [ -e "$src" ]; then
    MOUNTS+=("-v" "$src:$dst:$opts")
  else
    echo "  mount $src NOT present, skipping" >&2
  fi
}

# Host device groups (same as run.sh minus debug and run, which studenti is not in).
HOST_GIDS=(
  20    # dialout - /dev/ttyUSB*
  29    # audio   - /dev/snd
  44    # video   - /dev/nvmap, /dev/nvhost-* (required by CUDA)
  106   # input   - /dev/input/event*
  109   # render  - /dev/dri/renderD*
)

declare -a GROUP_ADDS=()
MAP_RAW=$(podman info --format '{{.Host.IDMappings.GIDMap}}')
for HG in "${HOST_GIDS[@]}"; do
  CG=$(echo "$MAP_RAW" | grep -oE '\{[0-9]+ '"$HG"' [0-9]+\}' | head -1 \
       | grep -oE '^\{[0-9]+' | tr -d '{' || true)
  if [ -z "$CG" ]; then
    echo "GID $HG not mapped in /etc/subgid, skipping" >&2
  else
    GROUP_ADDS+=("--group-add" "$CG")
    echo "  $HG (host) -> $CG (container)" >&2
  fi
done

for f in /usr/lib/aarch64-linux-gnu/libcudnn*.so* \
         /usr/lib/aarch64-linux-gnu/libnvinfer*.so* \
         /usr/lib/aarch64-linux-gnu/libnvonnxparser*.so* \
         /usr/lib/aarch64-linux-gnu/libnvparsers*.so* \
         /usr/lib/aarch64-linux-gnu/libnvcaffe_parser*.so* \
         /usr/lib/aarch64-linux-gnu/libcublas*.so* \
         /usr/lib/aarch64-linux-gnu/libcufft*.so* \
         /usr/lib/aarch64-linux-gnu/libcurand*.so* \
         /usr/lib/aarch64-linux-gnu/libcusolver*.so* \
         /usr/lib/aarch64-linux-gnu/libcusparse*.so* \
         /usr/lib/aarch64-linux-gnu/libcupti*.so* \
         /usr/lib/aarch64-linux-gnu/libnpp*.so* \
         /usr/lib/aarch64-linux-gnu/libnvjpeg*.so* \
         /usr/lib/aarch64-linux-gnu/libnvToolsExt*.so* \
         /usr/lib/aarch64-linux-gnu/libnvrtc*.so* ; do
  m "$f" "$f"
done

for f in /usr/include/curses.h /usr/include/ncurses*.h /usr/include/term.h \
         /usr/include/termcap.h /usr/include/unctrl.h /usr/include/eti.h \
         /usr/lib/aarch64-linux-gnu/libncurses*.so* /usr/lib/aarch64-linux-gnu/libtinfo*.so* \
         /usr/lib/aarch64-linux-gnu/pkgconfig/ncurses*.pc /usr/lib/aarch64-linux-gnu/pkgconfig/tinfo*.pc; do
  m "$f" "$f"
done

while read -r d; do
  m "$d" "$d"
done < <(grep -rhoE '/[A-Za-z0-9_./+-]*(dist|site)-packages/[A-Za-z0-9_./+-]*include' \
           --include='*.cmake' /opt/ros/humble/share 2>/dev/null | sort -u)

# Note: /dev is the host's (as in run.sh), so /dev/pts would be the host's terminals,
# where sshd cannot chown the session tty and closes interactive logins
# ("chown(/dev/pts/0, 1000, 5) failed"). The --mount type=devpts below gives the
# container its own terminals; the host's /dev/pts is not affected.

# AGIBOT_* variables and DDS profile: copied from agi's ~/.aima by setup-studenti.sh,
# because studenti cannot read /home/agi/.aima.
ENV_ARGS=()
if [ -r "$BASE/config/agibot.env" ]; then
  ENV_ARGS=("--env-file" "$BASE/config/agibot.env")
else
  echo "  $BASE/config/agibot.env missing, skipping AGIBOT_* env" >&2
fi
m "$BASE/config/ros_dds_configuration.xml" /etc/ros_dds_configuration.xml

# Student-specific persistent mounts: the agibotx2-students repository is the home.
[ -d "$STUD_HOME" ] || { echo "$STUD_HOME missing: clone agibotx2-students there" >&2; exit 1; }
m "$STUD_HOME"            /home/studente               rw
# Firmware aimdk_msgs and robot URDF (for Foxglove), refreshed by setup-studenti.sh.
m "$BASE/firmware/aimdk_msgs" /opt/agibot/aimdk_msgs    ro
m "$BASE/firmware/x2_urdf"    /opt/agibot/x2_urdf       ro
m "$BASE/sshd-keys"       /etc/ssh/keys                ro
m "$BASE/secrets/studente.hash" /run/secrets/studente.hash ro

if podman ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "stopping & removing old $NAME..."
  podman rm -f "$NAME" >/dev/null
fi

echo "starting $NAME from $IMAGE (ssh port $SSH_PORT)..."
podman run -d --name "$NAME" \
  --restart=always \
  --ipc=host --network=host --pid=host \
  --device nvidia.com/gpu=all \
  "${GROUP_ADDS[@]}" \
  -e HOME=/home/studente \
  -e SSH_PORT="$SSH_PORT" \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/ros_dds_configuration.xml \
  -e PATH=/opt/ros/humble/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -e LD_LIBRARY_PATH=/usr/local/lib:/usr/local/cuda/lib64:/opt/ros/humble/lib:/host-libs/aarch64-linux-gnu \
  "${ENV_ARGS[@]}" \
  -v /etc/machine-id:/etc/machine-id:ro \
  -v /usr/lib/aarch64-linux-gnu:/host-libs/aarch64-linux-gnu:ro \
  -v /opt/ros:/opt/ros:ro \
  -v /usr/local/bin/aima:/usr/local/bin/aima:ro \
  -v /dev:/dev:rslave \
  --mount type=devpts,destination=/dev/pts \
  -v /run/dbus:/run/dbus:rslave \
  "${MOUNTS[@]}" \
  "$IMAGE"
