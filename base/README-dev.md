# Developer container — AgiBot X2 (development unit 10.0.1.41)

Main development container (`aimdk-dev`), based on the official AgiBot image
(AgiBot guide, ch. 4.4 "Developing in a container"). It has ROS 2 Humble, the AimDK SDK, the GPU
and access to the robot's topics and services.

---

## Configuration

| | |
|---|---|
| Access | SSH to the host as `agi`, then `podman exec` |
| Container | `aimdk-dev` (image `agi/aimdk-dev:dev`) |
| User in the container | `root` (maps to `agi` on the host, rootless podman) |
| Persistent data | only `/home/agi/aimdk` (same path inside and outside the container) |
| Network | the robot's (`--network=host`) |
| Time zone | **Italian** (`TZ=Europe/Rome`) |
| Startup | **manual**: after a robot reboot the container is stopped |

**Difference from the original AgiBot container:** the official image sets `TZ=Asia/Shanghai`.
`-e TZ=Europe/Rome` has been added to `~/aimdk-image/run.sh`, so times and logs are in Italian
time. If the container is recreated with an original AgiBot `run.sh`, Chinese time comes back.

---

## 1. Entering the container

```bash
ssh agi@10.0.10.201
podman start aimdk-dev          # only if it is stopped (e.g. after a robot reboot)
podman exec -it aimdk-dev bash
```

ROS is loaded automatically. For the SDK, in every new terminal:

```bash
source ~/aimdk/install/local_setup.bash
```

To leave: `exit` (the container stays on).

---

## 2. What is kept and what is lost

- **Kept:** everything in `~/aimdk` (code, build, scripts).
- **Lost** when the container is recreated: packages installed with `apt`/`pip` and files
  outside `~/aimdk`. Save your work in `~/aimdk`.

| Command (on the host) | Purpose |
|---|---|
| `podman ps -a` | container status |
| `podman start aimdk-dev` | start |
| `podman restart aimdk-dev` | restart (apt packages are kept) |
| `bash ~/aimdk-image/run.sh` | recreate the container from scratch (apt packages are lost) |

---

## 3. Building the SDK

```bash
cd ~/aimdk && colcon build
```

The `~/aimdk/foxglove` folder contains a `COLCON_IGNORE` file: colcon skips it.

---

## 4. Visualizing data with Foxglove

Foxglove shows the robot's data in the browser. A **bridge** runs in the container, reading ROS
topics and sending them over the network; you connect to the bridge from your PC's browser.

### Starting the bridge (in the container)

```bash
~/aimdk/foxglove/run.sh
```

The script loads the firmware message definitions (`~/aimdk/foxglove/firmware_msgs`), publishes
the 3D model on `/robot_description` and starts the bridge on port **8770**. Keep the terminal
open; press `Ctrl+C` to stop it.

- Port **8770** because the student container uses 8765: this way both can run together.
  For another port: `~/aimdk/foxglove/run.sh 8771`.
- The bridge is **read-only**: no commands can be sent to the robot from Foxglove.
- Topics too heavy for Wi-Fi (uncompressed images, full point cloud) are not transmitted:
  use the `.../compressed` and `..._down_sampling` versions.

### Connecting from the browser

1. Open <https://app.foxglove.dev> (Chrome or Edge) and sign in with an account.
2. **Open connection** → **Foxglove WebSocket** → `ws://10.0.10.201:8770`.
3. Add panels with **Add panel**: *Image* for cameras, *Plot* or *Raw Messages* for
   joints and IMU, *3D* for lidar and the robot model.

### The robot's 3D model

In the **3D** panel settings (gear icon):

1. **Scene → Mesh up axis → Z-up**: without this, the robot's parts appear scattered.
2. **Frame → Display frame → `pelvis`**.
3. **Custom layers → + → URDF**, Source = **Topic**, topic `/robot_description`.

### After a firmware update

The message definitions must be copied again from the firmware. From the host, as `agi`:

```bash
F=~/aimdk/foxglove/firmware_msgs; C=/agibot/software/common; R=share/ament_index/resource_index; rm -rf $F && mkdir -p $F/lib $F/share $F/$R/packages $F/$R/rosidl_interfaces && cp -r $C/share/aimdk_msgs $F/share/aimdk_msgs && cp $C/$R/packages/aimdk_msgs $F/$R/packages/ && cp $C/$R/rosidl_interfaces/aimdk_msgs $F/$R/rosidl_interfaces/ && cp -L $C/lib/libaimdk_msgs__* $F/lib/
```
