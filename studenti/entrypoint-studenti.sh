#!/bin/bash
# Main process of the student container: prepare sshd and run it in the foreground.
set -euo pipefail

SSH_PORT="${SSH_PORT:-2222}"
echo "Port ${SSH_PORT}" > /etc/ssh/sshd_config.d/00-port.conf

# Host keys: created on the host by setup-studenti.sh and mounted read-only
# (/home/agi/studenti/sshd-keys -> /etc/ssh/keys), so they cannot be changed from here.
for t in ed25519 rsa; do
  if [ ! -r "/etc/ssh/keys/ssh_host_${t}_key" ]; then
    echo "ERROR: /etc/ssh/keys/ssh_host_${t}_key missing: run setup-studenti.sh on the host" >&2
    exit 1
  fi
done

# Password of "studente": a SHA-512 hash created on the host by setup-studenti.sh.
if [ -s /run/secrets/studente.hash ]; then
  usermod -p "$(cat /run/secrets/studente.hash)" studente
else
  echo "WARNING: /run/secrets/studente.hash missing, password login disabled" >&2
fi

# sshd drops the supplementary groups given with --group-add (video, render, audio...),
# and SSH sessions get their groups from /etc/group: register them for "studente",
# otherwise GPU (/dev/nvmap), audio and other devices are not accessible.
for g in $(awk '/^Groups:/{for(i=2;i<=NF;i++) print $i}' /proc/self/status); do
  [ "$g" = 0 ] && continue
  name=$(getent group "$g" | cut -d: -f1 || true)
  if [ -z "$name" ]; then name="hostdev$g"; groupadd -g "$g" "$name"; fi
  usermod -aG "$name" studente
done

# SSH sessions do not inherit this process's environment: export the variables
# that run-studenti.sh passed (ROS/CUDA paths, DDS profile, AGIBOT_*) via PAM.
: > /etc/environment
for v in PATH LD_LIBRARY_PATH FASTRTPS_DEFAULT_PROFILES_FILE TZ $(compgen -e | grep '^AGIBOT_' || true); do
  printf '%s="%s"\n' "$v" "${!v-}" >> /etc/environment
done

# First start on an empty home: give the user the default shell files.
if [ ! -f /home/studente/.bashrc ]; then
  cp -n /etc/skel/.bashrc /etc/skel/.profile /home/studente/ 2>/dev/null || true
  chown 1000:1000 /home/studente/.bashrc /home/studente/.profile 2>/dev/null || true
fi

mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e
