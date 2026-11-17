# Container studenti — AgiBot X2 (unità di sviluppo 10.0.1.41)

Container di sviluppo per gli studenti: entrano via SSH direttamente nel container, hanno `sudo`
solo al suo interno e nessun accesso al sistema del robot. Istruzioni per gli studenti in
[README-studenti.md](README-studenti.md).

Realizzato su: X2 Ultra, firmware v1.1.4, podman 4.6.2 (guida AgiBot, cap. 4.4 "在容器中开发").

---

## Configurazione

| | |
|---|---|
| Accesso studenti | `ssh -p 2222 studente@10.0.10.201` — password `mivia` |
| Container | `aimdk-studenti` (immagine `agi/aimdk-studenti:dev`) |
| Utente nel container | `studente`, con `sudo` valido solo nel container |
| Utente host proprietario | `studenti` (UID 1101): niente sudo, niente login |
| Dati persistenti | `/home/agi/studenti/` (sopravvive agli aggiornamenti firmware) |
| Home studenti | `/home/agi/studenti/home` → `/home/studente` nel container (contiene la copia dell'SDK) |
| Avvio | automatico all'accensione del robot e dopo un crash |

Opzioni del container: le stesse del `run.sh` AgiBot, con queste differenze:
- utente `studenti` invece di `agi`;
- `sshd` sulla porta 2222 come processo principale;
- terminali propri (`devpts`);
- gruppi dei dispositivi senza `debug` e `run`;
- chiavi SSH in sola lettura;
- ora italiana;
- `--restart=always`.

---

## File del kit

| File | Dove va sul robot | A cosa serve |
|---|---|---|
| `base/Dockerfile` | `~/aimdk-image/` | immagine ufficiale AgiBot `agi/aimdk-dev:dev` |
| `base/run.sh` | `~/aimdk-image/` | container ufficiale `aimdk-dev` per `agi` (non serve agli studenti) |
| `studenti/Dockerfile.studenti` | `~/aimdk-image/studenti/` | immagine studenti (ufficiale + SSH, sudo, utente `studente`, PyTorch GPU + YOLO) |
| `studenti/entrypoint-studenti.sh` | `~/aimdk-image/studenti/` | avvio del container: prepara e lancia `sshd` |
| `studenti/sshd-studenti.conf` | `~/aimdk-image/studenti/` | configurazione SSH del container |
| `studenti/run-studenti.sh` | `~/aimdk-image/studenti/` | crea il container (versione adattata di `run.sh`) |
| `studenti/setup-studenti.sh` | `~/aimdk-image/studenti/` | installa / ripristina tutto (da lanciare con sudo) |

---

## Librerie GPU (PyTorch e YOLO)

L'immagine studenti include PyTorch con GPU e Ultralytics YOLO (esempio
`ros2 run py_examples yolo_detection`). Versioni, allineate al robot (Jetson Orin NX, JetPack 6.2):

| Componente | Versione | Da dove arriva |
|---|---|---|
| driver GPU, cuDNN 9.3, TensorRT 10.7 | quelle del robot | montati dall'host all'avvio (`--device nvidia.com/gpu=all`) |
| librerie CUDA 12.6 (cudart, cuBLAS, cuFFT, …) | 12.6 | apt, repository NVIDIA Jetson `r36.4` |
| cuSPARSELt | 0.7.1 | archivio NVIDIA |
| PyTorch / torchvision | 2.5.0 (nv24.08) / 0.20.0 | pacchetti per JetPack 6 |
| numpy | 1.26.1 | pip, uguale a quello del robot |
| Ultralytics | 8.4.215 | pip, senza `opencv-python` (usa l'OpenCV 4.5.4 di ROS) |

- cuDNN **non** va installato nell'immagine: quello montato dal robot ci finirebbe sopra.
- numpy deve restare 1.x: il container monta in sola lettura gli header numpy del robot
  (`/usr/local/lib/python3.10/dist-packages/numpy/core/include`), che servono al ROS dell'host.
- Se un aggiornamento firmware cambia JetPack, aggiornare `JETPACK_REPO`, `CUDA_VER` e i
  pacchetti torch in testa alla sezione GPU di `Dockerfile.studenti`, poi `--rebuild`.
- Il modello `yolo11n.pt` sta nella home degli studenti (`~/aimdk/src/py_examples/py_examples/data/`),
  non nell'immagine.

---

## Installazione

Come `agi` sull'unità di sviluppo.

**1. Immagine ufficiale** (lunga, compila OpenCV):

```bash
cd ~/aimdk-image && podman build -t agi/aimdk-dev:dev .
```

**2. Ambiente studenti** (chiede la password di sudo e quella da dare agli studenti):

```bash
sudo bash ~/aimdk-image/studenti/setup-studenti.sh
```

Lo script crea l'utente `studenti`, la cartella `/home/agi/studenti` con la copia dell'SDK,
l'immagine e il container, e l'avvio automatico. Si può rilanciare quando serve.

**3. SDK degli studenti** (una volta, dentro il container):

```bash
source /opt/ros/humble/setup.bash
cd ~/aimdk && colcon build
```

---

## Comandi di `setup-studenti.sh`

| Comando | A cosa serve |
|---|---|
| `sudo bash ~/aimdk-image/studenti/setup-studenti.sh` | installazione o ripristino (es. dopo un aggiornamento firmware) |
| `… --password` | cambia la password degli studenti |
| `… --recreate` | ricrea il container (dopo modifiche a `run-studenti.sh`); si perdono i pacchetti apt |
| `… --rebuild` | ricostruisce l'immagine e ricrea il container (dopo modifiche a Dockerfile/entrypoint); si perdono i pacchetti apt |
| `… --refresh-msgs` | riallinea `aimdk_msgs` della copia studenti a `~/aimdk`; poi ricompilare l'SDK nel container |

La home degli studenti non viene mai toccata da questi comandi.

---

## Gestione del container

Dall'host, come `agi`. Il container appartiene all'utente `studenti`, quindi i comandi podman
vanno lanciati come `studenti`:

```bash
cd / && sudo -u studenti XDG_RUNTIME_DIR=/run/user/1101 podman <comando>
```

| `<comando>` | A cosa serve |
|---|---|
| `ps -a` | stato del container |
| `logs aimdk-studenti` | log di SSH |
| `restart aimdk-studenti` | riavvio (i pacchetti apt restano) |
| `exec -it aimdk-studenti bash` | entrare nel container come root |

Backup del lavoro degli studenti:

```bash
tar czf ~/backup-studenti-$(date +%F).tgz --exclude='home/aimdk/build' --exclude='home/aimdk/install' --exclude='home/aimdk/log' -C /home/agi/studenti home
```

---

## Dopo un aggiornamento firmware

L'aggiornamento cancella la configurazione di sistema (utente, permessi, avvio automatico), ma non
`/home/agi`. Per ripristinare:

```bash
sudo bash ~/aimdk-image/studenti/setup-studenti.sh
```

Se manca l'immagine `agi/aimdk-dev:dev`, prima ricostruirla (Installazione, punto 1).

**Messaggi per Foxglove.** Lo script Foxglove degli studenti (`~/foxglove/run.sh` nel container)
usa una copia dei messaggi del firmware, che il container non può leggere da solo. Dopo ogni
aggiornamento va ricopiata (come `agi`, chiede la password di sudo):

```bash
F=/home/agi/studenti/home/.foxglove/firmware_msgs; C=/agibot/software/common; R=share/ament_index/resource_index; sudo rm -rf $F && sudo mkdir -p $F/lib $F/share $F/$R/packages $F/$R/rosidl_interfaces && sudo cp -r $C/share/aimdk_msgs $F/share/aimdk_msgs && sudo cp $C/$R/packages/aimdk_msgs $F/$R/packages/ && sudo cp $C/$R/rosidl_interfaces/aimdk_msgs $F/$R/rosidl_interfaces/ && sudo cp -L $C/lib/libaimdk_msgs__* $F/lib/ && sudo chmod -R a+rX /home/agi/studenti/home/.foxglove && ls $F/share/aimdk_msgs/msg | wc -l
```

L'ultimo numero stampato (circa 450) è il numero di messaggi copiati.

---

## Note importanti

- **Permessi di `/home/agi`:** a ogni avvio il firmware rimette `/home/agi` a 750. Il setup aggiunge una regola
  (`/etc/systemd/system/user@1101.service.d/10-home-traverse.conf`) che li riapplica prima di
  avviare il container: senza, il container non parte.
- **Rete:** il robot deve avere sempre lo stesso IP sulla Wi-Fi (10.0.10.201). Se PC e robot sono su
  bande diverse (2,4/5 GHz) il router può non far passare il traffico tra loro.
  In alternativa, via cavo sulla porta di sviluppo: `ssh -p 2222 studente@10.0.200.41`.
- **Cosa possono fare gli studenti:** nessun accesso ai file dell'host oltre alla loro home.
  Possono però comandare il robot via ROS 2: serve la supervisione fisica.
- **`aimdk_msgs`:** l'SDK pubblico non contiene i messaggi interni del robot (es.
  `RobotNetworkInfo`): su quei topic `ros2` risponde "message type is invalid".
