# Установка и настройка Wazuh (ESXi 7 + K8s + ARCHIVE)

Сценарий **до 100 агентов** (compact). ОС гостя: **РЕД ОС 8** / **Astra Linux SE 1.7** / **Astra Linux SE 1.8**.

Архитектура (ESXi, разделы, жизненный цикл данных): [wazuh-architecture.md](wazuh-architecture.md).

Версия манифестов: `wazuh-kubernetes` **v4.14.7**.

Порядок работ:

1. Создать ВМ в ESXi 7  
2. Установить ОС с нужной разметкой  
3. Подготовить ОС (РЕД / Astra)  
4. Поднять K8s + Wazuh  
5. Настроить сервер ARCHIVE + ежедневные снимки + ISM  
6. Научиться Restore и просмотру в Dashboard  
7. Подключить агентов  

---

## 0. Адреса (замените на свои)

| Хост | IP |
|---|---|
| k8s-indexer | 10.10.10.11 |
| k8s-manager | 10.10.10.12 |
| k8s-dashboard | 10.10.10.13 |
| wazuh-archive | 10.10.10.14 |
| VIP (MetalLB/HAProxy) | 10.10.10.20 |
| Сеть NFS/K8s | 10.10.10.0/24 |

---

# Часть 1. Создание ВМ в ESXi 7

Для каждой ВМ: **Host** → **Create/Register VM** → **Create a new virtual machine**.

## 1.1. Общие поля мастера

| Шаг | Параметр | Значение |
|---|---|---|
| Name | имя | `k8s-indexer` / `k8s-manager` / `k8s-dashboard` / `wazuh-archive` |
| Compatibility | | **ESXi 7.0 and later** |
| Guest OS | Family | Linux |
| Guest OS | Version | Other 4.x or later Linux (64-bit) **или** RHEL 8 / Debian 10–12 64-bit |
| Firmware (Customize hardware → VM Options → Boot Options) | | **EFI** |
| Secure Boot | | **Off** |

## 1.2. Customize hardware — шаблон

| Устройство | Настройка |
|---|---|
| CPU | по таблице ниже; Cores per Socket = 1; CPU Hot Plug = **Off**; Hardware virtualization = **Off** |
| Memory | по таблице; для indexer: **Reserve all guest memory** = Yes; Memory Hot Plug = **Off** |
| SCSI Controller 0 | **VMware Paravirtual** |
| Hard disk 1 | OS, node `SCSI(0:0)`, Thin или Thick Lazy Zeroed |
| Hard disk 2 | DATA (если нужен), node `SCSI(0:1)`, для indexer/manager: **Thick Provision Eager Zeroed** |
| Network adapter 1 | **VMXNET 3**, нужный port group, Connect = Yes |
| CD/DVD | Datastore ISO нужной ОС, Connect at power on |

## 1.3. Ресурсы по ВМ

| VM | vCPU | RAM | Disk1 OS | Disk2 DATA | Eager Zeroed DATA | Datastore DATA |
|---|---:|---:|---:|---:|---|---|
| k8s-indexer | 8 | 32 Gi (reserve all) | 80 Gi | **300 Gi** | Yes | **SSD** |
| k8s-manager | 8 | 24 Gi | 80 Gi | **100 Gi** | Yes | SSD |
| k8s-dashboard | 4 | 8 Gi | 60 Gi | — | — | any |
| wazuh-archive | 4 | 8 Gi | 60 Gi | **1024 Gi** | Lazy/Thin OK | HDD OK |

Создайте все 4 ВМ, подключите ISO, включите питание.

---

# Часть 2. Разметка дисков при установке ОС

## 2.1. Принципы

- Таблица разделов: **GPT**, загрузка **EFI**
- **Swap не создавать**
- Диск OS (`sda`): только система
- Диск DATA (`sdb`): **не смешивать** с root; разметить после установки или одной partition в installer

## 2.2. OS-диск (`sda`) — все ВМ

| Mount | Размер | FS РЕД ОС 8 | FS Astra | Flags |
|---|---:|---|---|---|
| `/boot/efi` | 600 MiB | EFI System (vfat) | EFI System (vfat) | esp |
| `/boot` | 1 GiB | xfs | ext4 | — |
| `/` | всё оставшееся от OS-диска | xfs | ext4 | — |
| swap | **нет** | — | — | — |

| ВМ | OS диск | ≈ размер `/` |
|---|---:|---:|
| indexer, manager | 80 Gi | ~78 Gi |
| dashboard, archive | 60 Gi | ~58 Gi |

### РЕД ОС 8 (Anaconda)

Installation Destination → **Custom** → Standard Partition (или LVM **только** для `/`, EFI и boot — стандартные partition):

1. Создать на `sda`: `/boot/efi` 600 MiB, `/boot` 1 GiB, `/` rest, xfs, **без swap**.
2. Диск `sdb` — **Leave as is** (разметим после).

### Astra SE 1.7 / 1.8

В разметке вручную (Guided — лучше не использовать «весь диск в один раздел», если видит оба диска):

1. На OS-диске: EFI 600M, `/boot` 1G ext4, `/` rest ext4, без swap.
2. DATA-диск пока не трогать (или сразу одна primary + mount — тогда сразу укажите точки из §2.3).

## 2.3. DATA-диск — целевое состояние после ОС

Выполнить после первого входа (команды ниже в частях 3–4). Итог:

| ВМ | Partition | FS | Mount | Каталоги |
|---|---|---|---|---|
| k8s-indexer | `/dev/sdb1` 300 Gi | xfs/ext4 | `/data/wazuh` | `indexer/` (+ позже NFS `/mnt/snapshots`) |
| k8s-manager | `/dev/sdb1` 100 Gi | xfs/ext4 | `/data/wazuh` | `manager-master/`, `manager-worker/` |
| k8s-dashboard | нет | — | — | — |
| wazuh-archive | `/dev/sdb1` 1 Ti | xfs/ext4 | `/mnt/snapshots` | содержимое NFS export |

Добить установку ОС: timezone, root/ssh key, сеть static IP из таблицы §0, hostname.

Установить **open-vm-tools** (РЕД: `dnf install open-vm-tools`; Astra: `apt install open-vm-tools`).

---

# Часть 3. РЕД ОС 8 — post-install на нодах K8s

На `k8s-indexer`, `k8s-manager`, `k8s-dashboard` (archive — часть 6).

## 3.1. Имя и hosts

```bash
hostnamectl set-hostname k8s-indexer   # своё имя

cat >/etc/hosts <<'EOF'
127.0.0.1 localhost
10.10.10.11 k8s-indexer
10.10.10.12 k8s-manager
10.10.10.13 k8s-dashboard
10.10.10.14 wazuh-archive
EOF
```

## 3.2. Пакеты, время, swap off

```bash
dnf -y update
dnf -y install curl wget tar git chrony yum-utils device-mapper-persistent-data \
  lvm2 ca-certificates conntrack-tools iptables iproute-tc socat ebtables ethtool \
  nfs-utils openssl open-vm-tools
systemctl enable --now chronyd vmtoolsd
swapoff -a
sed -ri 's/.*swap.*/#&/' /etc/fstab
free -h   # Swap = 0
```

## 3.3. sysctl / modules

```bash
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
vm.max_map_count                    = 262144
fs.file-max                         = 65536
EOF
sysctl --system
```

## 3.4. firewalld

```bash
systemctl enable --now firewalld
firewall-cmd --permanent --add-port={6443,10250,179,1514,1515,443}/tcp
firewall-cmd --permanent --add-port=2379-2380/tcp
firewall-cmd --permanent --add-port=4789/udp
firewall-cmd --permanent --add-port=30000-32767/tcp
firewall-cmd --permanent --add-service={nfs,rpc-bind,mountd}
firewall-cmd --reload
```

## 3.5. Разметка DATA (`sdb`) — indexer / manager

```bash
lsblk
parted /dev/sdb --script mklabel gpt mkpart primary xfs 1MiB 100%
mkfs.xfs -f /dev/sdb1
mkdir -p /data/wazuh
UUID=$(blkid -s UUID -o value /dev/sdb1)
echo "UUID=${UUID} /data/wazuh xfs defaults,noatime 0 0" >>/etc/fstab
mount -a
# indexer:
mkdir -p /data/wazuh/indexer /mnt/snapshots
# manager:
mkdir -p /data/wazuh/manager-master /data/wazuh/manager-worker
```

## 3.6. containerd + kubeadm

```bash
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf -y install containerd.io
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

cat >/etc/yum.repos.d/kubernetes.repo <<'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
dnf -y install kubelet kubeadm kubectl --disableexcludes=kubernetes
systemctl enable --now kubelet
```

---

# Часть 4. Astra SE 1.7 и 1.8 — post-install на нодах K8s

## 4.1. Общее для 1.7 и 1.8

```bash
hostnamectl set-hostname k8s-indexer
# /etc/hosts — как в 3.1

apt-get update && apt-get -y upgrade
apt-get -y install curl wget tar git ca-certificates apt-transport-https gnupg \
  lsb-release chrony conntrack iptables iproute2 socat ebtables ethtool \
  nfs-common openssl open-vm-tools
systemctl enable --now chrony open-vm-tools
swapoff -a
sed -ri 's/.*swap.*/#&/' /etc/fstab
```

Sysctl/modules — **как §3.3**.

**MAC/ЗПС:** до containerd согласуйте с ИБ запуск kubelet/containerd/NFS/privileged CNI.

### Firewall

```bash
apt-get -y install ufw
ufw allow 22/tcp
ufw allow 6443/tcp
ufw allow 2379:2380/tcp
ufw allow 10250/tcp
ufw allow 179/tcp
ufw allow 4789/udp
ufw allow 1514:1515/tcp
ufw allow 443/tcp
ufw allow 2049/tcp
ufw allow 30000:32767/tcp
ufw --force enable
```

### DATA disk

```bash
parted /dev/sdb --script mklabel gpt mkpart primary ext4 1MiB 100%
mkfs.ext4 -F /dev/sdb1
mkdir -p /data/wazuh /mnt/snapshots
UUID=$(blkid -s UUID -o value /dev/sdb1)
echo "UUID=${UUID} /data/wazuh ext4 defaults,noatime 0 0" >>/etc/fstab
mount -a
mkdir -p /data/wazuh/{indexer,manager-master,manager-worker}
```

## 4.2. containerd

```bash
apt-get -y install containerd
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
# На 1.7 проверьте версию ≥ 1.6
```

## 4.3. Kubernetes packages

**Astra 1.8** (если есть доступ к pkgs.k8s.io / зеркалу):

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get -y install kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet
```

**Astra 1.7** (часто offline):

```bash
dpkg -i kubelet_*.deb kubeadm_*.deb kubectl_*.deb cri-tools_*.deb kubernetes-cni_*.deb
apt-get -f install -y
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet
```

На 1.7 Calico — только VXLAN (без eBPF).

---

# Часть 5. Kubernetes + Wazuh (все ОС)

## 5.1. kubeadm init / join

На `k8s-indexer`:

```bash
kubeadm init \
  --apiserver-advertise-address=10.10.10.11 \
  --pod-network-cidr=192.168.0.0/16 \
  --control-plane-endpoint=10.10.10.11:6443

mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
kubeadm token create --print-join-command
```

На manager и dashboard — `kubeadm join ...`.

```bash
kubectl taint nodes k8s-indexer node-role.kubernetes.io/control-plane- || true
kubectl label node k8s-indexer role=indexer --overwrite
kubectl label node k8s-manager role=manager --overwrite
kubectl label node k8s-dashboard role=dashboard --overwrite
```

## 5.2. Calico + MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml
kubectl get nodes
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
```

```yaml
# metallb-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: wazuh-pool, namespace: metallb-system }
spec: { addresses: ["10.10.10.20-10.10.10.20"] }
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: wazuh-l2, namespace: metallb-system }
```

```bash
kubectl apply -f metallb-pool.yaml
```

## 5.3. Static PV под DATA

```yaml
# pv-wazuh.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: wazuh-local-ssd }
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: pv-wazuh-indexer }
spec:
  capacity: { storage: 300Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: wazuh-local-ssd
  local: { path: /data/wazuh/indexer }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - { key: role, operator: In, values: [indexer] }
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: pv-wazuh-manager-master }
spec:
  capacity: { storage: 50Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: wazuh-local-ssd
  local: { path: /data/wazuh/manager-master }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - { key: role, operator: In, values: [manager] }
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: pv-wazuh-manager-worker }
spec:
  capacity: { storage: 50Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: wazuh-local-ssd
  local: { path: /data/wazuh/manager-worker }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - { key: role, operator: In, values: [manager] }
```

```bash
kubectl apply -f pv-wazuh.yaml
```

## 5.4. Деплой Wazuh с production limits

```bash
git clone https://github.com/wazuh/wazuh-kubernetes.git -b v4.14.7 --depth=1
cd wazuh-kubernetes
bash wazuh/certs/indexer_cluster/generate_certs.sh
bash wazuh/certs/dashboard_http/generate_certs.sh
```

Обязательные значения в overlays/`local-env`:

| | Значение |
|---|---|
| indexer replicas | 1 |
| worker replicas | 1 |
| indexer PVC | 300Gi, SC `wazuh-local-ssd` |
| master PVC / lim | 50Gi / **2 CPU / 4 Gi** |
| worker PVC / lim | 50Gi / **4 CPU / 8 Gi** |
| indexer lim | **4 CPU / 24 Gi**, `OPENSEARCH_JAVA_OPTS=-Xms8g -Xmx8g` |
| dashboard lim | 2 CPU / 4 Gi |
| nodeSelector | role=* |

В StatefulSet indexer добавьте volumeMount NFS (после части 6):

```yaml
volumeMounts:
- name: snapshots
  mountPath: /mnt/snapshots
volumes:
- name: snapshots
  hostPath: { path: /mnt/snapshots, type: Directory }
```

И в config OpenSearch: `path.repo: ["/mnt/snapshots"]`.

```bash
kubectl apply -k envs/local-env/
kubectl get pods -n wazuh -o wide -w
kubectl exec -n wazuh wazuh-manager-master-0 -- cat /var/ossec/etc/authd.pass
```

Сменить пароли admin. Не включать полный `wazuh-archives-*` без отдельного диска.

---

# Часть 6. Сервер ARCHIVE — установка и ежедневная архивация

ВМ `wazuh-archive` **не** входит в Kubernetes.

## 6.1. ОС и раздел DATA (все дистрибутивы)

Hostname `wazuh-archive`, IP `10.10.10.14`, hosts как в §3.1, chrony, open-vm-tools, **без swap**.

Разметка DATA:

```bash
# РЕД ОС
parted /dev/sdb --script mklabel gpt mkpart primary xfs 1MiB 100%
mkfs.xfs -f /dev/sdb1
# Astra
# mkfs.ext4 -F /dev/sdb1

mkdir -p /mnt/snapshots
UUID=$(blkid -s UUID -o value /dev/sdb1)
# РЕД:
echo "UUID=${UUID} /mnt/snapshots xfs defaults,noatime 0 0" >>/etc/fstab
# Astra: fs=ext4
mount -a
df -h /mnt/snapshots   # ~1 Ti
```

## 6.2. NFS server

### РЕД ОС 8

```bash
dnf -y install nfs-utils
echo "/mnt/snapshots 10.10.10.0/24(rw,sync,no_root_squash,no_subtree_check)" >/etc/exports
systemctl enable --now nfs-server
exportfs -rav
firewall-cmd --permanent --add-service={nfs,rpc-bind,mountd}
firewall-cmd --reload
```

### Astra 1.7 / 1.8

```bash
apt-get -y install nfs-kernel-server
echo "/mnt/snapshots 10.10.10.0/24(rw,sync,no_root_squash,no_subtree_check)" >/etc/exports
exportfs -rav
systemctl enable --now nfs-kernel-server
```

Права (UID процесса wazuh-indexer в контейнере — проверьте `kubectl exec ... -- id`):

```bash
chown -R 1000:1000 /mnt/snapshots
chmod 755 /mnt/snapshots
```

## 6.3. Mount NFS на хосте k8s-indexer

```bash
# РЕД: nfs-utils; Astra: nfs-common — уже стоят
mount -t nfs 10.10.10.14:/mnt/snapshots /mnt/snapshots
echo "10.10.10.14:/mnt/snapshots /mnt/snapshots nfs defaults,_netdev,noatime 0 0" >>/etc/fstab
mount -a
touch /mnt/snapshots/.writetest && rm /mnt/snapshots/.writetest
```

Пересоздайте pod indexer, если уже запущен, чтобы подхватить hostPath + `path.repo`.

## 6.4. Зарегистрировать snapshot repository

Dashboard: **Indexer management → Snapshot Management → Repositories → Create**

- Name: `wazuh-archive-repo`
- Type: **Shared file system**
- Location: `/mnt/snapshots`

API:

```bash
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u admin:'PASS' \
  -H 'Content-Type: application/json' \
  -X PUT 'https://localhost:9200/_snapshot/wazuh-archive-repo' \
  -d '{"type":"fs","settings":{"location":"/mnt/snapshots","compress":true}}'
```

Проверка:

```bash
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u admin:'PASS' \
  'https://localhost:9200/_snapshot/wazuh-archive-repo/_all?pretty'
```

## 6.5. Ежедневная архивация (каждый день в 02:00)

### Вариант A — Snapshot Management Policy (предпочтительно)

Dashboard → **Snapshot Management → Snapshot policies → Create policy**:

| Поле | Значение |
|---|---|
| Policy name | `daily-wazuh-alerts` |
| Repository | `wazuh-archive-repo` |
| Source indices | `wazuh-alerts-*` |
| Include cluster state | **Yes** |
| Schedule | `0 2 * * *` (cron, 02:00 ежедневно) |
| Snapshot retention | keep **365 days** (или max N снимков ≥ 365) |

Сохраните политику, дождитесь первого SUCCESS (можно Run now для теста).

### Вариант B — cron на admin-хосте (если SM UI недоступен)

```bash
# /usr/local/bin/wazuh-daily-snapshot.sh
set -euo pipefail
PASS=...   # из secret / vault
NAME="daily-$(date -u +%Y.%m.%d)"
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u "admin:${PASS}" \
  -H 'Content-Type: application/json' \
  -X PUT "https://localhost:9200/_snapshot/wazuh-archive-repo/${NAME}?wait_for_completion=true" \
  -d '{"indices":"wazuh-alerts-*","include_global_state":true}'
```

Cron: `0 2 * * * root /usr/local/bin/wazuh-daily-snapshot.sh >>/var/log/wazuh-snap.log 2>&1`

Плюс отдельный job очистки снимков старше 365 дней через Snapshot Management retention или API delete.

## 6.6. ISM: удаление с HOT после 90 дней

**Только после 7–14 дней успешных daily snapshots.**

Dashboard → Index Management → State management policies:

- Pattern: `wazuh-alerts-*`
- State `hot` → transition to `delete` when `min_index_age: 90d`
- State `delete` → action `delete`

Так HOT SSD не растёт бесконечно; история остаётся в снимках на `wazuh-archive`.

## 6.7. Мониторинг ARCHIVE

Ежедневно проверять:

1. Последний snapshot = SUCCESS, age < 36h  
2. `df -h /mnt/snapshots` на archive < 80%  
3. `exportfs -v` и mount на indexer живы  
4. `events_dropped` / `discarded_count` = 0 на worker  

---

# Часть 7. Как достать архив и смотреть в Wazuh

Снимки на NFS **не отображаются** в Discover, пока не сделан Restore.

## 7.1. Через Dashboard (основной способ)

1. Войти в Wazuh Dashboard.  
2. ☰ → **Indexer management** → **Snapshot Management** → **Snapshots**.  
3. Найти снимок нужной даты (или `daily-YYYY.MM.DD`).  
4. Actions → **Restore**.  
5. Выбрать индексы (`wazuh-alerts-2025.01.15` и т.п.).  
6. Advanced: не включать лишние rename, если хотите исходные имена (следите за конфликтами с живыми индексами).  
7. Дождаться завершения Restore.  
8. ☰ → **Discover** (или Security events / Threat Hunting).  
9. Index pattern: `wazuh-alerts-*`.  
10. Выставить календарь на даты восстановленного периода.  
11. Анализировать как обычно (фильтры, agent.name, rule.id …).  
12. **После расследования** удалить восстановленные индексы (Index Management → Delete), чтобы освободить HOT.  
13. Снимок на ARCHIVE при этом **не удаляется**.

## 7.2. Через API

```bash
# список снимков
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u admin:'PASS' \
  'https://localhost:9200/_snapshot/wazuh-archive-repo/_all?pretty'

# restore одного индекса
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u admin:'PASS' \
  -H 'Content-Type: application/json' \
  -X POST 'https://localhost:9200/_snapshot/wazuh-archive-repo/daily-2025.01.15/_restore' \
  -d '{"indices":"wazuh-alerts-2025.01.15","include_global_state":false}'
```

Свободное место на `/data/wazuh/indexer` должно покрывать размер индекса + ~20%.

## 7.3. Типовые ошибки Restore

| Симптом | Что делать |
|---|---|
| Repository verification failed | NFS mount, firewall 2049, path.repo, chown 1000 |
| No space | освободить HOT / временно расширить vmdk 300 Gi в ESXi |
| Index already exists | restore под другим именем или удалить конфликтующий |
| Пустой Discover | неверный time range / index pattern |

---

# Часть 8. Агенты и приёмка

## 8.1. Агенты

```bash
export WAZUH_MANAGER='10.10.10.20'
export WAZUH_REGISTRATION_SERVER='10.10.10.20'
export WAZUH_REGISTRATION_PASSWORD='...'
# пакет агента 4.14.x
```

## 8.2. Чеклист

- [ ] 4 ВМ в ESXi 7: PVSCSI, VMXNET3, EFI, ресурсы по таблице  
- [ ] Разделы: EFI+boot+/, без swap; DATA смонтирован  
- [ ] 3 ноды K8s Ready, labels role=*  
- [ ] 4 пода Wazuh Running, PVC Bound  
- [ ] VIP :1514/:1515/:443  
- [ ] NFS archive → indexer, repository OK  
- [ ] Тестовый snapshot SUCCESS  
- [ ] Daily policy 02:00 создана  
- [ ] Учебный Restore → данные видны в Discover → индекс удалён с HOT  
- [ ] ISM 90d включён после обкатки снимков  
- [ ] open-vm-tools, chrony, пароли сменены  

## 8.3. Расширение дисков в ESXi позже

1. Edit VM → увеличить vmdk DATA.  
2. В госте: `parted` resize / `xfs_growfs` или `resize2fs`.  
3. Для PVC: при static PV — обновить capacity PV/PVC согласованно.

---

# Часть 9. Сводка отличий ОС

| | РЕД ОС 8 | Astra 1.7 | Astra 1.8 |
|---|---|---|---|
| Разметка installer | Anaconda | Astra installer | Astra installer |
| FS | xfs | ext4 | ext4 |
| NFS server | nfs-utils | nfs-kernel-server | nfs-kernel-server |
| K8s packages | dnf/rpm | чаще offline deb | apt или offline |
| MAC | SELinux | ЗПС | ЗПС |
| Дальше (K8s/Wazuh/ARCHIVE) | одинаково | одинаково | одинаково |

---

## Ссылки

- Архитектура: [wazuh-architecture.md](wazuh-architecture.md)  
- Snapshots NFS (Wazuh): https://documentation.wazuh.com/current/user-manual/wazuh-indexer/migrating-wazuh-indices.html  
- Deploy K8s: https://documentation.wazuh.com/current/deployment-options/deploying-with-kubernetes/index.html  
