# NixOS Container Infrastructure with Automated Timed MAC Rotator

Infrastruttura dichiarativa NixOS containerizzata per il deployment su host Debian tramite **LXC** e **systemd-nspawn**, dotata di un modulo automatizzato per la rotazione temporizzata del MAC address e il rinnovo del lease DHCP senza conservazione del DUID (DHCP Unique Identifier).

---

## 🎯 Obiettivi e Caratteristiche

- **Generazione MAC IEEE 802 LAA Unicast**: Generazione crittograficamente sicura da `/dev/urandom` con bitwise masking per garantire che il bit Unicast (I/G = 0) e il bit Locally Administered (U/L = 1) siano conformi (secondo nibble del primo byte forzato a `2`, `6`, `A` o `E`).
- **Anonimizzazione DHCP e Bypass DUID**: `systemd-networkd` configurato con `ClientIdentifier = "mac"` e `Anonymize = true`, prevenendo l'invio del DUID RFC 4361 legato a `/etc/machine-id`. Ogni rotazione appare al server DHCP come un dispositivo hardware completamente nuovo.
- **Schedulazione Temporizzata con Jitter Casuale**: `systemd.timer` parametrizzabile con `OnCalendar` e `RandomizedDelaySec` per evitare pattern temporali prevedibili.
- **Footprint Minimale**: Costruito tramite il modulo standard NixOS `lxc-container.nix` e `tarball.nix`, con documentazione e manuali rimossi per mantenere l'archivio rootfs leggero e veloce da estrarre.
- **Supporto Duale LXC & systemd-nspawn**: Provisioning automatizzato sia su `/var/lib/machines` (nspawn/machinectl) che su `/var/lib/lxc` (LXC standard).
- **Provisioning Host Debian Idempotente**: Script di setup automatico per installare dipendenze, creare il bridge isolato `br0` (`10.100.0.1/24`), configurare `dnsmasq` e applicare regole di masquerading NAT con iptables.

---

## 📁 Struttura del Repository

```
.
├── flake.nix                       # Definizione del Flake NixOS, configurazione base-container e build tarball
├── modules/
│   └── network-mac-rotator.nix    # Modulo NixOS: rotatore MAC, configurazione systemd-networkd, service e timer
├── host/
│   ├── debian-setup.sh             # Script di provisioning per l'host Debian (bridge br0, dnsmasq, iptables)
│   ├── nspawn-template.nspawn      # Template di configurazione systemd-nspawn con CAP_NET_ADMIN e binding br0
│   └── lxc-template.conf           # Template di configurazione LXC con veth su br0 e privilege drop controllato
├── Makefile                        # Target di build, deploy, test e teardown per nspawn e LXC
└── README.md                       # Documentazione completa dell'infrastruttura
```

---

## 🧠 Dettagli Tecnici di Implementazione

### 1. Generazione MAC e Conformità IEEE 802 LAA
Un indirizzo MAC Ethernet standard a 48 bit è composto da 6 byte: `b0:b1:b2:b3:b4:b5`.
Nel primo byte `b0`:
- **Bit 0 (I/G - Individual/Group)**: `0` = Unicast, `1` = Multicast/Broadcast.
- **Bit 1 (U/L - Universal/Local)**: `0` = Universally Administered (OUI assegnato da IEEE), `1` = Locally Administered Address (LAA).

Applicando la maschera `(byte0 & 0xFE) | 0x02`, il nibble meno significativo del primo byte risulterà sempre appartenere all'insieme `{2, 6, A, E}` (es. `02:...`, `16:...`, `3A:...`, `FE:...`), garantendo traffico unicast valido e assenza di conflitti OUI globali.

### 2. Disaccoppiamento DUID e Rinnovo DHCP
Per evitare che il server DHCP riconosca il container dopo un cambio MAC, `systemd-networkd` è configurato con:
```nix
systemd.network.networks."10-container-network" = {
  dhcpV4Config = {
    ClientIdentifier = "mac"; # Invia Option 61 basata su MAC anziché RFC 4361 DUID
    Anonymize = true;         # Disabilita l'invio di opzioni identificative non necessarie
    RapidCommit = false;      # Forza un ciclo DORA standard a 4 vie
  };
};
```

---

## ⚙️ Opzioni NixOS del Modulo (`services.macRotator`)

| Opzione | Tipo | Default | Descrizione |
|---|---|---|---|
| `services.macRotator.enable` | `boolean` | `false` | Abilita il servizio di rotazione MAC, il timer e la configurazione DHCPv4. |
| `services.macRotator.interface` | `string` | `"eth0"` | Nome dell'interfaccia di rete target (fallback automatico a `host0`/veth se non trovata). |
| `services.macRotator.calendarWindow` | `string` | `"*-*-* 02:00:00"` | Espressione `systemd.time(7)` `OnCalendar` per l'orario base di scatto del timer. |
| `services.macRotator.randomDelay` | `string` | `"3h"` | Finestra di jitter casuale (`RandomizedDelaySec`) sommata all'orario base. |
| `services.macRotator.leaseWaitSec` | `integer` | `3` | Secondi di attesa dopo il link-up per consentire la negoziazione DHCP. |

---

## 🚀 Guida Rapida al Deployment

### Prerequisiti
1. Host con **Debian 11/12** (o derivata compatibile) con accesso `sudo`.
2. **Nix** con supporto a Flakes abilitato (`experimental-features = nix-command flakes`).

---

### Step 1: Provisioning dell'Host Debian
Esegui lo script di configurazione per creare il bridge `br0` (`10.100.0.1/24`), avviare `dnsmasq` e abilitare il NAT:
```bash
make host-setup
# oppure direttamente:
sudo ./host/debian-setup.sh
```

Verifica lo stato del bridge host:
```bash
ip addr show br0
systemctl status dnsmasq
```

---

### Step 2: Compilazione del RootFS NixOS
Compila il pacchetto tarball rootfs minimale:
```bash
make build
# oppure:
nix build .#tarball --extra-experimental-features "nix-command flakes"
```
Il tarball compresso generato sarà disponibile in `result/tarball/nixos-container-rootfs.tar.xz`.

---

### Step 3: Deployment del Container

#### Opzione A: Deployment con `systemd-nspawn`
Per creare ed eseguire un container con identificatore `node-01`:
```bash
make spawn-nspawn ID=node-01
```
Il container verrà estratto in `/var/lib/machines/node-01` e avviato con la configurazione `/etc/systemd/nspawn/node-01.nspawn`.

Comandi utili per `systemd-nspawn`:
```bash
# Verifica stato del container
make status-nspawn ID=node-01
# oppure:
sudo machinectl status node-01

# Trigger rotazione manuale per test
make test-rotation-nspawn ID=node-01

# Accesso shell all'interno del container
sudo machinectl shell node-01

# Arresto e pulizia
make stop-nspawn ID=node-01
make destroy-nspawn ID=node-01
```

---

#### Opzione B: Deployment con `LXC`
Per creare ed eseguire un container LXC con identificatore `node-01`:
```bash
make spawn-lxc ID=node-01
```
Il rootfs verrà estratto in `/var/lib/lxc/node-01/rootfs` e avviato in background via `lxc-start`.

Comandi utili per `LXC`:
```bash
# Verifica stato del container
make status-lxc ID=node-01
# oppure:
sudo lxc-info -n node-01

# Trigger rotazione manuale per test
make test-rotation-lxc ID=node-01

# Accesso shell all'interno del container
sudo lxc-attach -n node-01

# Arresto e pulizia
make stop-lxc ID=node-01
make destroy-lxc ID=node-01
```

---

## 🔍 Comandi di Verifica e Diagnostica

### 1. All'interno del Container NixOS
Accedi alla shell del container (`machinectl shell <ID>` o `lxc-attach -n <ID>`) ed esegui:

```bash
# Verifica indirizzo MAC e flag dell'interfaccia
ip link show eth0

# Verifica stato del link e lease DHCP in systemd-networkd
networkctl status eth0

# Esecuzione manuale dello script di rotazione
rotate-mac

# Verifica log del servizio systemd
journalctl -u mac-rotator.service --no-pager -n 20

# Verifica pianificazione del timer e prossimo scatto casuale
systemctl list-timers mac-rotator.timer
```

### 2. Sull'Host Debian
Per verificare l'assegnazione dei lease DHCP isolati e la progressione dei MAC address:
```bash
# Visualizza i lease attivi registrati da dnsmasq sul bridge br0
cat /var/lib/misc/dnsmasq.br0.leases

# Monitora in tempo reale le richieste DHCP
journalctl -u dnsmasq -f
```

---

## 🔒 Sicurezza e Isolamento

- **Capability Minime**: All'interno dei container viene concessa esplicitamente `CAP_NET_ADMIN` (e `CAP_NET_RAW`), necessaria per modificare lo stato del link e l'indirizzo hardware (`ip link set dev eth0 address ...`), mantenendo i privilegi non necessari bloccati.
- **Rete Isolata**: Il bridge `br0` separa completamente il traffico dei container dalla LAN fisica dell'host, esponendoli verso l'esterno solo tramite NAT/Masquerading.
