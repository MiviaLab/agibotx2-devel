# Student container — AgiBot X2 (development unit 10.0.1.41)

Development container for the students: they log in via SSH directly into the container, have
`sudo` only inside it and no access to the robot's system. The students' home inside the
container is the [agibotx2-students](https://github.com/MiviaLab/agibotx2-students) repository,
which also contains their instructions (`STUDENT-GUIDE.md`, `EXAMPLES.md`).

Built on: X2 Ultra, firmware v1.1.4, podman 4.6.2 (AgiBot guide, ch. 4.4 "Developing in a container").

---

## Configuration

| | |
|---|---|
| Student access | `ssh -p 2222 studente@10.0.10.201` — password `mivia` |
| Container | `aimdk-studenti` (image `agi/aimdk-studenti:dev`) |
| User in the container | `studente`, with `sudo` valid only inside the container |
| Owning host user | `studenti` (UID 1101): no sudo, no login |
| Persistent data | `/home/agi/studenti/` (survives firmware updates) |
| Students' home | `/home/agi/studenti/agibotx2-students` (the repository) → `/home/studente` in the container |
| Firmware files | `/home/agi/studenti/firmware` → `/opt/agibot` in the container (read-only) |
| Startup | automatic at robot boot and after a crash |

Container options: the same as AgiBot's `run.sh`, with these differences:
- user `studenti` instead of `agi`;
- `sshd` on port 2222 as the main process;
- its own terminals (`devpts`);
- device groups without `debug` and `run`;
- read-only SSH host keys;
- Italian time zone;
- the students' SDK (`~/aimdk/install/local_setup.bash`) sourced automatically in every
  interactive shell (`/etc/bash.bashrc`); each group builds its own workspace on top of it;
- `--restart=always`.

---

## Kit files

| File | Where it goes on the robot | Purpose |
|---|---|---|
| `base/Dockerfile` | `~/aimdk-image/` | official AgiBot image `agi/aimdk-dev:dev` |
| `base/run.sh` | `~/aimdk-image/` | official `aimdk-dev` container for `agi` (not needed by the students) |
| `studenti/Dockerfile.studenti` | `~/aimdk-image/studenti/` | student image (official + SSH, sudo, user `studente`, PyTorch GPU + YOLO + Whisper + Piper TTS) |
| `studenti/entrypoint-studenti.sh` | `~/aimdk-image/studenti/` | container startup: prepares and launches `sshd` |
| `studenti/sshd-studenti.conf` | `~/aimdk-image/studenti/` | SSH configuration of the container |
| `studenti/run-studenti.sh` | `~/aimdk-image/studenti/` | creates the container (adapted version of `run.sh`) |
| `studenti/setup-studenti.sh` | `~/aimdk-image/studenti/` | installs / restores everything (run with sudo) |

---

## GPU libraries (PyTorch, YOLO, Whisper, Piper)

The student image includes PyTorch with GPU, Ultralytics YOLO (example
`ros2 run py_examples yolo_detection`), Whisper (example `audio_transcriber`, ONNX model run by
ONNX Runtime with TensorRT) and Piper text-to-speech (example `italian_piper_tts`). Versions,
aligned with the robot (Jetson Orin NX, JetPack 6.2):

| Component | Version | Source |
|---|---|---|
| GPU driver, cuDNN 9.3, TensorRT 10.7 | those of the robot | mounted from the host at startup (`--device nvidia.com/gpu=all`) |
| CUDA 12.6 libraries (cudart, cuBLAS, cuFFT, …) | 12.6 | apt, NVIDIA Jetson repository `r36.4` |
| cuSPARSELt | 0.7.1 | NVIDIA archive |
| PyTorch / torchvision | 2.5.0 (nv24.08) / 0.20.0 | packages for JetPack 6 |
| numpy | 1.26.1 | pip, same as the robot |
| Ultralytics | 8.4.215 | pip, without `opencv-python` (uses ROS's OpenCV 4.5.4) |
| onnxruntime-gpu | 1.23.0 (with TensorRT and CUDA providers) | pip, Jetson AI Lab index `jp6/cu126` (needs apt `libcudla-12-6`) |
| transformers / optimum / optimum-onnx | 4.53.2 / 2.1.0 / 0.1.0 | pip (Whisper export and inference) |
| silero-vad | 6.2.3 | pip, `--no-deps` |
| piper-tts / pathvalidate | 1.8.0 / 3.3.1 | pip, `--no-deps` |

- cuDNN must **not** be installed in the image: the one mounted from the robot would end up on top of it.
- numpy must stay 1.x: the container mounts the robot's numpy headers read-only
  (`/usr/local/lib/python3.10/dist-packages/numpy/core/include`), which the host's ROS needs.
- If a firmware update changes JetPack, update `JETPACK_REPO`, `CUDA_VER` and the torch
  packages at the top of the GPU section of `Dockerfile.studenti`, then `--rebuild`.
- Never install the PyPI `onnxruntime` package: it is CPU only and hides `onnxruntime-gpu`.
  `silero-vad` and `piper-tts` depend on it, which is why they are installed with `--no-deps`.
  Check also the students' `~/.local`: a `pip install --user` there hides the image packages.
- The models are in the students' repository, not in the image: the Piper voice in
  `aimdk/models/piper/` (versioned), Whisper in `aimdk/models/whisper/` (about 4 GB, not
  versioned: `audio_transcriber` downloads and exports it on its first start, about 10 minutes,
  and caches the TensorRT engines in `trt_cache/`; delete that folder after a TensorRT update).
- The `yolo11n.pt` model lives in the students' repository
  (`aimdk/src/py_examples/py_examples/data/`), not in the image.

---

## Installation

As `agi` on the development unit.

**1. Official image** (long, it compiles OpenCV):

```bash
cd ~/aimdk-image && podman build -t agi/aimdk-dev:dev .
```

**2. Student environment** (asks for the sudo password and for the password to give to the students):

```bash
sudo bash ~/aimdk-image/studenti/setup-studenti.sh
```

The script creates the `studenti` user and the `/home/agi/studenti` folder, clones the
`agibotx2-students` repository into it if missing (with the SDK copy; the HTML docs are copied
from `~/aimdk/docs`), copies the firmware messages and URDF, builds the image and the container,
and sets up autostart. It can be run again whenever needed.

**3. Students' SDK** (once, inside the container):

```bash
source /opt/ros/humble/setup.bash
cd ~/aimdk && colcon build
```

---

## `setup-studenti.sh` commands

| Command | Purpose |
|---|---|
| `sudo bash ~/aimdk-image/studenti/setup-studenti.sh` | installation or restore (e.g. after a firmware update); also refreshes the firmware files for Foxglove |
| `… --password` | changes the students' password |
| `… --recreate` | recreates the container (after changes to `run-studenti.sh`); apt packages are lost |
| `… --rebuild` | rebuilds the image and recreates the container (after changes to Dockerfile/entrypoint); apt packages are lost |
| `… --refresh-msgs` | re-syncs `aimdk_msgs` of the students' copy with `~/aimdk`; then rebuild the SDK in the container |

These commands never touch the students' work (only `--refresh-msgs` overwrites
`aimdk/src/aimdk_msgs`).

---

## Managing the container

From the host, as `agi`. The container belongs to the `studenti` user, so podman commands
must be run as `studenti`:

```bash
cd / && sudo -u studenti XDG_RUNTIME_DIR=/run/user/1101 podman <command>
```

| `<command>` | Purpose |
|---|---|
| `ps -a` | container status |
| `logs aimdk-studenti` | SSH logs |
| `restart aimdk-studenti` | restart (apt packages are kept) |
| `exec -it aimdk-studenti bash` | enter the container as root |

**Updating the students' repository.** After the setup the mounted copy
(`/home/agi/studenti/agibotx2-students`) belongs to the container user (a subordinate UID on the
host): `agi` can neither read it fully nor run git on it ("dubious ownership"). Do not edit it
directly. Instead:

1. Edit, commit and push in agi's own clone `~/agibotx2-students`
   (`git clone https://github.com/MiviaLab/agibotx2-students.git ~/agibotx2-students` if missing).
2. Update the students' home from inside the container:

   ```bash
   ssh -p 2222 studente@10.0.10.201 'cd ~ && git pull'
   ```

   If `git pull` refuses because of local changes in the mounted copy, align it with
   `git fetch && git reset --hard origin/main` (ignored files such as the groups' `*_ws`
   workspaces, `aimdk/build` and `aimdk/docs` are not touched).

Backup of the students' work:

```bash
sudo tar czf ~/backup-studenti-$(date +%F).tgz --exclude='agibotx2-students/aimdk/build' --exclude='agibotx2-students/aimdk/install' --exclude='agibotx2-students/aimdk/log' --exclude='agibotx2-students/aimdk/docs' -C /home/agi/studenti agibotx2-students
```

---

## After a firmware update

The update wipes the system configuration (user, permissions, autostart), but not
`/home/agi`. To restore it:

```bash
sudo bash ~/aimdk-image/studenti/setup-studenti.sh
```

If the `agi/aimdk-dev:dev` image is missing, rebuild it first (Installation, step 1).

The same command also re-copies the firmware messages and the URDF used by the students'
Foxglove script (`~/foxglove/run.sh`), which the container cannot read on its own.

---

## Important notes

- **Permissions of `/home/agi`:** at every boot the firmware resets `/home/agi` to 750. The setup
  adds a rule (`/etc/systemd/system/user@1101.service.d/10-home-traverse.conf`) that re-applies
  them before starting the container: without it, the container does not start.
- **Network:** the robot must always have the same IP on Wi-Fi (10.0.10.201). If PC and robot
  are on different bands (2.4/5 GHz), the router may not forward traffic between them.
  Alternatively, via cable on the development port: `ssh -p 2222 studente@10.0.200.41`.
- **What students can do:** no access to host files other than their home. They can however
  command the robot via ROS 2: physical supervision is required.
- **`aimdk_msgs`:** the public SDK does not contain the robot's internal messages (e.g.
  `RobotNetworkInfo`): on those topics `ros2` answers "message type is invalid". The Foxglove
  script uses the firmware copy in `/opt/agibot/aimdk_msgs`, which includes them.
