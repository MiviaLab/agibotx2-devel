# AgiBot X2 — development containers

Build and setup files for the two development containers on the **AgiBot X2** humanoid robot
(development unit, Jetson Orin NX, JetPack 6.2) used in the MiviaLab:

| Container | Image | Who uses it | How to enter |
|---|---|---|---|
| `aimdk-dev` | `agi/aimdk-dev:dev` | developers / instructors | `ssh agi@10.0.10.201`, then `podman exec -it aimdk-dev bash` |
| `aimdk-studenti` | `agi/aimdk-studenti:dev` | students | `ssh -p 2222 studente@10.0.10.201` |

Both run ROS 2 Humble with the AimDK SDK, use the robot's GPU and share the robot's network, so
they can reach its ROS 2 topics and services. The student image is built **on top of** the
official one.

This repository is for administrators. The students' instructions, their copy of the SDK and
the Foxglove scripts are in the companion repository
[agibotx2-students](https://github.com/MiviaLab/agibotx2-students), which is mounted as the
students' home inside `aimdk-studenti`.

---

## Repository layout

```
agibotx2-devel/
├── README.md                     this file
├── base/                         official AgiBot development container
│   ├── Dockerfile                image agi/aimdk-dev:dev (ROS Humble deps, OpenCV 4.8, ruckig)
│   ├── run.sh                    creates container aimdk-dev (host ROS, CUDA, devices mounted)
│   └── README-dev.md             how to use aimdk-dev
└── studenti/                     student container
    ├── Dockerfile.studenti       image agi/aimdk-studenti:dev = base + SSH, sudo, user
    │                             "studente", PyTorch GPU, YOLO, Whisper, Piper TTS
    ├── entrypoint-studenti.sh    container main process: prepares and runs sshd
    ├── sshd-studenti.conf        SSH server configuration of the container
    ├── run-studenti.sh           creates container aimdk-studenti (adapted from base/run.sh)
    ├── setup-studenti.sh         installs / restores the whole student environment (sudo)
    └── README-setup.md           administrator guide for the student container
```

### `base/`

The official AgiBot image and launch script (AgiBot guide, ch. 4.4), with one change: `run.sh`
sets `TZ=Europe/Rome`. The image contains only the system dependencies: ROS (`/opt/ros`), CUDA,
cuDNN and TensorRT are mounted from the host at runtime. The container runs as `agi` (rootless
podman) and persists only `/home/agi/aimdk`. Details: [base/README-dev.md](base/README-dev.md).

### `studenti/`

A locked-down container for students:

- owned by the unprivileged host user `studenti` (UID 1101): container root is **not** `agi`;
- students log in via SSH (port 2222) as `studente`, with `sudo` valid only in the container;
- home `/home/studente` = `/home/agi/studenti/agibotx2-students` (the students' repository);
- firmware messages and robot URDF (for Foxglove) mounted read-only in `/opt/agibot`;
- starts automatically at boot and restarts after a crash.

Details, commands and maintenance: [studenti/README-setup.md](studenti/README-setup.md).

---

## Usage

On the robot, as `agi`. The files are expected in `~/aimdk-image/` (`base/` contents at the top
level, `studenti/` as a subfolder):

```bash
git clone https://github.com/MiviaLab/agibotx2-devel.git ~/agibotx2-devel
mkdir -p ~/aimdk-image/studenti
cp ~/agibotx2-devel/base/{Dockerfile,run.sh} ~/aimdk-image/
cp ~/agibotx2-devel/studenti/*.{sh,conf} ~/agibotx2-devel/studenti/Dockerfile.studenti ~/aimdk-image/studenti/
```

**1. Official image and developer container**

```bash
cd ~/aimdk-image && podman build -t agi/aimdk-dev:dev .   # long: compiles OpenCV
bash ~/aimdk-image/run.sh                                  # optional: creates aimdk-dev
```

**2. Student environment**

```bash
sudo bash ~/aimdk-image/studenti/setup-studenti.sh
```

It creates the `studenti` user, `/home/agi/studenti` (cloning `agibotx2-students` there if
missing), the student image and container, and autostart. Then, once, build the SDK inside the
student container: `cd ~/aimdk && colcon build`.

| Task | Command |
|---|---|
| restore after a firmware update | `sudo bash ~/aimdk-image/studenti/setup-studenti.sh` |
| change the students' password | `… setup-studenti.sh --password` |
| apply changes to `run-studenti.sh` | `… setup-studenti.sh --recreate` |
| apply changes to `Dockerfile.studenti` / entrypoint | `… setup-studenti.sh --rebuild` |
| update `aimdk_msgs` of the students' SDK | `… setup-studenti.sh --refresh-msgs` |

---

## Persistent data on the robot

Firmware updates wipe the system but keep `/home/agi`:

| Path | Content |
|---|---|
| `/home/agi/aimdk` | SDK of the developer container |
| `/home/agi/aimdk-image` | the files of this repository |
| `/home/agi/studenti/agibotx2-students` | students' home (repository + SDK copy + their work); owned by the container user, updated with `git pull` from inside the container |
| `/home/agi/agibotx2-students` | agi's working clone of the students' repository: edit, commit and push here |
| `/home/agi/studenti/firmware` | firmware `aimdk_msgs` and URDF, refreshed by `setup-studenti.sh` |
| `/home/agi/studenti/{config,secrets,sshd-keys,bin,build}` | DDS/env config, password hash, SSH host keys, installed scripts |
