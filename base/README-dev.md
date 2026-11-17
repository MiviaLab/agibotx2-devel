# Container developer — AgiBot X2 (unità di sviluppo 10.0.1.41)

Container di sviluppo principale (`aimdk-dev`), basato sull'immagine ufficiale AgiBot
(guida AgiBot, cap. 4.4 "在容器中开发"). Ha ROS 2 Humble, l'SDK AimDK, la GPU e l'accesso a
topic e servizi del robot.

---

## Configurazione

| | |
|---|---|
| Accesso | SSH sull'host come `agi`, poi `podman exec` |
| Container | `aimdk-dev` (immagine `agi/aimdk-dev:dev`) |
| Utente nel container | `root` (corrisponde a `agi` sull'host, podman rootless) |
| Dati persistenti | solo `/home/agi/aimdk` (stesso percorso dentro e fuori dal container) |
| Rete | quella del robot (`--network=host`) |
| Ora | **italiana** (`TZ=Europe/Rome`) |
| Avvio | **manuale**: dopo un riavvio del robot il container è spento |

**Differenza dal container originale AgiBot:** l'immagine ufficiale imposta `TZ=Asia/Shanghai`.
In `~/aimdk-image/run.sh` è stato aggiunto `-e TZ=Europe/Rome`, quindi orari e log sono in ora
italiana. Se il container viene ricreato con un `run.sh` originale AgiBot, torna l'ora cinese.

---

## 1. Entrare nel container

```bash
ssh agi@10.0.10.201
podman start aimdk-dev          # solo se è spento (es. dopo un riavvio del robot)
podman exec -it aimdk-dev bash
```

ROS si carica da solo. Per l'SDK, in ogni nuovo terminale:

```bash
source ~/aimdk/install/local_setup.bash
```

Per uscire: `exit` (il container resta acceso).

---

## 2. Cosa resta e cosa si perde

- **Resta:** tutto quello che sta in `~/aimdk` (codice, build, script).
- **Si perde** quando il container viene ricreato: pacchetti installati con `apt`/`pip` e file
  fuori da `~/aimdk`. Salvate il vostro lavoro in `~/aimdk`.

| Comando (sull'host) | A cosa serve |
|---|---|
| `podman ps -a` | stato del container |
| `podman start aimdk-dev` | accensione |
| `podman restart aimdk-dev` | riavvio (i pacchetti apt restano) |
| `bash ~/aimdk-image/run.sh` | ricrea il container da zero (si perdono i pacchetti apt) |

---

## 3. Compilare l'SDK

```bash
cd ~/aimdk && colcon build
```

La cartella `~/aimdk/foxglove` contiene un file `COLCON_IGNORE`: colcon la salta.

---

## 4. Visualizzare i dati con Foxglove

Foxglove mostra nel browser i dati del robot. Nel container gira un **bridge** che legge i topic ROS
e li manda in rete; dal browser del PC vi collegate al bridge.

### Avviare il bridge (nel container)

```bash
~/aimdk/foxglove/run.sh
```

Lo script carica le definizioni dei messaggi del firmware (`~/aimdk/foxglove/firmware_msgs`),
pubblica il modello 3D su `/robot_description` e avvia il bridge sulla porta **8770**. Lasciate
aperto il terminale; per fermarlo `Ctrl+C`.

- Porta **8770** perché il container studenti usa la 8765: così possono funzionare insieme.
  Per un'altra porta: `~/aimdk/foxglove/run.sh 8771`.
- Il bridge è in **sola lettura**: da Foxglove non si mandano comandi al robot.
- Non vengono trasmessi i topic troppo pesanti per la Wi-Fi (immagini non compresse, point cloud
  completa): usate le versioni `.../compressed` e `..._down_sampling`.

### Collegarsi dal browser

1. Aprite <https://app.foxglove.dev> (Chrome o Edge) ed entrate con un account.
2. **Open connection** → **Foxglove WebSocket** → `ws://10.0.10.201:8770`.
3. Aggiungete i pannelli con **Add panel**: *Image* per le camere, *Plot* o *Raw Messages* per
   giunti e IMU, *3D* per lidar e modello del robot.

### Modello 3D del robot

Nelle impostazioni del pannello **3D** (rotellina):

1. **Scene → Mesh up axis → Z-up**: senza, i pezzi del robot appaiono sparsi.
2. **Frame → Display frame → `pelvis`**.
3. **Custom layers → + → URDF**, Source = **Topic**, topic `/robot_description`.

### Dopo un aggiornamento firmware

Le definizioni dei messaggi vanno ricopiate dal firmware. Dall'host, come `agi`:

```bash
F=~/aimdk/foxglove/firmware_msgs; C=/agibot/software/common; R=share/ament_index/resource_index; rm -rf $F && mkdir -p $F/lib $F/share $F/$R/packages $F/$R/rosidl_interfaces && cp -r $C/share/aimdk_msgs $F/share/aimdk_msgs && cp $C/$R/packages/aimdk_msgs $F/$R/packages/ && cp $C/$R/rosidl_interfaces/aimdk_msgs $F/$R/rosidl_interfaces/ && cp -L $C/lib/libaimdk_msgs__* $F/lib/
```