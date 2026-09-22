# Установка и настройка Wazuh в Kubernetes (до 100 агентов)

Поэтапная инструкция для **компактного production-варианта** (4 пода / 3 ВМ) на:

- **РЕД ОС 8**
- **Astra Linux SE 1.7**
- **Astra Linux SE 1.8**

Связанный sizing: [wazuh-kubernetes-architecture.md](wazuh-kubernetes-architecture.md).

Версия манифестов в примерах: **Wazuh 4.14.x** (`wazuh-kubernetes` tag `v4.14.7`). При смене версии подставьте актуальный tag с [релизов](https://github.com/wazuh/wazuh-kubernetes/tags).

---

## 0. Целевая топология (общая для всех ОС)

| ВМ | Роль | vCPU | RAM | OS disk | Data SSD | Поды |
|---|---|---:|---:|---:|---:|---|
| `k8s-indexer` | control-plane + worker | 8 | 32 Gi | 80 Gi | **300 Gi** | `wazuh-indexer-0` |
| `k8s-manager` | worker | 8 | 16 Gi | 80 Gi | **100 Gi** | `wazuh-manager-master-0`, `wazuh-manager-worker-0` |
| `k8s-dashboard` | worker | 4 | 8 Gi | 60 Gi | — | `wazuh-dashboard` |

**Поды:** 1 master + 1 worker + 1 indexer + 1 dashboard.

**Сеть:**

| Порт | Куда | Назначение |
|---:|---|---|
| 1514/TCP | LB → worker | события агентов |
| 1515/TCP | LB → master | enrollment (authd) |
| 443/TCP | Ingress/LB → dashboard | UI |
| 6443/TCP | control-plane | Kubernetes API |
| 10250/TCP | все ноды | kubelet |
| 1516, 55000, 9200, 9300 | только internal | cluster / API / indexer |

IP в примерах (замените на свои):

| Хост | IP |
|---|---|
| `k8s-indexer` | `10.10.10.11` |
| `k8s-manager` | `10.10.10.12` |
| `k8s-dashboard` | `10.10.10.13` |
| VIP LB (MetalLB / HAProxy) | `10.10.10.20` |

---

## 1. Общие требования (все ОС)

Перед установкой на **каждой** ВМ:

1. Статический IP, DNS (или `/etc/hosts`), синхронизация времени (NTP/chrony).
2. Отключённый swap (обязательно для kubelet).
3. `vm.max_map_count=262144` (требование OpenSearch/Wazuh indexer).
4. Открытые порты между нодами кластера и с агентов на VIP `:1514` / `:1515` / `:443`.
5. Доступ к registry образов (`docker.io` / зеркало) или локальный registry с образами Wazuh.
6. Data-диски отформатированы и смонтированы **до** создания PV/PVC (см. этап 4).

Рекомендуемый стек:

- Kubernetes **1.28–1.30** (kubeadm)
- containerd
- CNI: Calico
- Storage: local-path-provisioner (или OpenEBS LocalPV) на data SSD
- LB: MetalLB (L2) **или** внешний HAProxy/Nginx на VIP
- Ingress (dashboard): nginx-ingress **или** NodePort/LoadBalancer

---

# Часть A. РЕД ОС 8

РЕД ОС 8 — RHEL-совместимая ОС (`dnf`, `firewalld`, SELinux). Команды выполнять от root или через `sudo`.

## A1. Подготовка ОС (на всех 3 ВМ)

### A1.1. Имя хоста и hosts

```bash
# на каждой ВМ — своё имя
hostnamectl set-hostname k8s-indexer   # или k8s-manager / k8s-dashboard

cat >/etc/hosts <<'EOF'
127.0.0.1   localhost
10.10.10.11 k8s-indexer
10.10.10.12 k8s-manager
10.10.10.13 k8s-dashboard
EOF
```

### A1.2. Обновление и базовые пакеты

```bash
dnf -y update
dnf -y install curl wget tar git chrony yum-utils device-mapper-persistent-data \
  lvm2 ca-certificates conntrack-tools iptables iproute-tc socat ebtables ethtool
systemctl enable --now chronyd
timedatectl set-ntp true
```

### A1.3. Swap off

```bash
swapoff -a
sed -ri 's/.*swap.*/#&/' /etc/fstab
free -h   # Swap должен быть 0B
```

### A1.4. Модули ядра и sysctl

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
sysctl vm.max_map_count   # ожидается 262144
```

### A1.5. SELinux

Для production на РЕД ОС обычно оставляют **Enforcing**. Если политики блокируют containerd/kubelet — временно:

```bash
getenforce
# при проблемах на этапе отладки:
# setenforce 0
# sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

После стабилизации верните Enforcing и добавьте нужные правила/`container-selinux`.

### A1.6. firewalld (порты)

На **всех** нодах:

```bash
systemctl enable --now firewalld

# Kubernetes
firewall-cmd --permanent --add-port=6443/tcp
firewall-cmd --permanent --add-port=2379-2380/tcp
firewall-cmd --permanent --add-port=10250/tcp
firewall-cmd --permanent --add-port=10259/tcp
firewall-cmd --permanent --add-port=10257/tcp
firewall-cmd --permanent --add-port=179/tcp          # Calico BGP (если BGP)
firewall-cmd --permanent --add-port=4789/udp        # Calico VXLAN

# Wazuh (на нодах, где будут LB/NodePort — или на всех worker)
firewall-cmd --permanent --add-port=1514/tcp
firewall-cmd --permanent --add-port=1515/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=30443/tcp       # если NodePort dashboard
firewall-cmd --permanent --add-port=30000-32767/tcp # NodePort range (при необходимости)

firewall-cmd --reload
```

Для Calico часто удобнее добавить интерфейс pod-сети в trusted zone после установки CNI — проверьте связность `pod ↔ pod`.

### A1.7. Data-диски

На `k8s-indexer` (300 Gi) и `k8s-manager` (100 Gi):

```bash
# пример: диск /dev/sdb
lsblk
mkfs.xfs -f /dev/sdb
mkdir -p /data/wazuh
UUID=$(blkid -s UUID -o value /dev/sdb)
echo "UUID=${UUID} /data/wazuh xfs defaults,noatime 0 0" >>/etc/fstab
mount -a
df -h /data/wazuh
```

Подкаталоги под local-path (создадите после установки provisioner или заранее):

```bash
# indexer
mkdir -p /data/wazuh/indexer && chmod 755 /data/wazuh/indexer
# manager (на k8s-manager)
mkdir -p /data/wazuh/manager-master /data/wazuh/manager-worker
```

---

## A2. containerd (РЕД ОС 8)

```bash
# Docker CE repo часто совместим с RHEL-like; при наличии корпоративного зеркала — используйте его
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
# Если репозиторий недоступен — установите containerd из зеркала РЕД ОС / внутреннего artifactory

dnf -y install containerd.io
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl status containerd --no-pager
```

Проверка:

```bash
ctr version
```

---

## A3. kubeadm, kubelet, kubectl (РЕД ОС 8)

```bash
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

> В закрытом контуре скачайте RPM с зеркала и установите через `dnf localinstall`.

---

## A4. Инициализация кластера (только на k8s-indexer)

```bash
kubeadm init \
  --apiserver-advertise-address=10.10.10.11 \
  --pod-network-cidr=192.168.0.0/16 \
  --control-plane-endpoint=10.10.10.11:6443
```

Настроить kubectl для admin:

```bash
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes
```

Сохранить join-команду:

```bash
kubeadm token create --print-join-command
```

На **k8s-manager** и **k8s-dashboard**:

```bash
kubeadm join 10.10.10.11:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>
```

Разрешить расписание подов на control-plane (compact-кластер из 3 нод):

```bash
kubectl taint nodes k8s-indexer node-role.kubernetes.io/control-plane- || true
kubectl taint nodes k8s-indexer node-role.kubernetes.io/master- || true
```

Метки ролей (anti-affinity / scheduling):

```bash
kubectl label node k8s-indexer   role=indexer --overwrite
kubectl label node k8s-manager   role=manager --overwrite
kubectl label node k8s-dashboard role=dashboard --overwrite
```

---

## A5. CNI Calico (РЕД ОС 8)

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml
kubectl -n kube-system get pods -l k8s-app=calico-node -w
kubectl get nodes   # STATUS = Ready
```

---

Далее общие этапы **C** (storage, LB, Wazuh) — одинаковы для всех ОС.

---

# Часть B. Astra Linux SE 1.7

Astra Linux SE **1.7** — Debian-based (ветка ~Debian 10), пакетный менеджер `apt`, свой репозиторий и мандатный контроль (PARSEC/MAC в режимах ЗПС).

## B1. Подготовка ОС (на всех 3 ВМ)

### B1.1. Имя и hosts

```bash
hostnamectl set-hostname k8s-indexer   # или k8s-manager / k8s-dashboard

cat >/etc/hosts <<'EOF'
127.0.0.1   localhost
10.10.10.11 k8s-indexer
10.10.10.12 k8s-manager
10.10.10.13 k8s-dashboard
EOF
```

### B1.2. Репозитории и обновление

Убедитесь, что подключены официальные репозитории Astra SE 1.7 (base + update). Пример (пути уточните по вашей поставке/ISO):

```bash
apt-get update
apt-get -y upgrade
apt-get -y install curl wget tar git ca-certificates apt-transport-https \
  gnupg lsb-release chrony conntrack iptables iproute2 socat ebtables ethtool \
  software-properties-common
systemctl enable --now chrony
```

### B1.3. Swap, sysctl, модули

```bash
swapoff -a
sed -ri 's/.*swap.*/#&/' /etc/fstab

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

### B1.4. Мандатный контроль / ЗПС (критично для Astra)

На Astra SE контейнеры и kubelet часто конфликтуют с усиленным MAC:

1. Уточните режим: `astra-modeswitch get` / документация вашей редакции.
2. Для K8s-нод обычно требуется:
   - разрешённый запуск containerd/kubelet в политике;
   - либо выделенный профиль «сервер контейнеров» по регламенту ИБ;
   - отключение/ослабление блокировок исполнения неподписанных бинарников на нодах K8s **по согласованию с ИБ**.
3. AppArmor-профили для containerd: при сбоях подов проверьте `dmesg` / `journalctl -u containerd`.

> Без согласования политик MAC установка kubeadm на SE часто «падает» на `kubelet NotReady` или `CreateContainerError`. Это ожидаемо — сначала согласуйте исключения для нод кластера.

### B1.5. Firewall (ufw / iptables)

Astra 1.7 может использовать `ufw` или ручной iptables. Пример через `ufw`:

```bash
apt-get -y install ufw
ufw allow 22/tcp
ufw allow 6443/tcp
ufw allow 2379:2380/tcp
ufw allow 10250/tcp
ufw allow 179/tcp
ufw allow 4789/udp
ufw allow 1514/tcp
ufw allow 1515/tcp
ufw allow 443/tcp
ufw allow 30000:32767/tcp
ufw --force enable
```

### B1.6. Data-диски

```bash
lsblk
mkfs.ext4 -F /dev/sdb
mkdir -p /data/wazuh
UUID=$(blkid -s UUID -o value /dev/sdb)
echo "UUID=${UUID} /data/wazuh ext4 defaults,noatime 0 0" >>/etc/fstab
mount -a
mkdir -p /data/wazuh/indexer /data/wazuh/manager-master /data/wazuh/manager-worker
```

---

## B2. containerd (Astra SE 1.7)

На 1.7 пакеты containerd из Debian Backports/внешних репо могут требовать зеркала. Предпочтительный путь — **версию containerd из вашего сертифицированного/внутреннего репозитория**.

```bash
# Вариант: пакет из Debian 10-совместимого репо / внутреннего зеркала
apt-get -y install containerd

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
```

Если пакет `containerd` старый (<1.6) — соберите/установите containerd 1.6+ из внутреннего artifactory (рекомендуется для K8s 1.28+).

---

## B3. kubeadm / kubelet / kubectl (Astra SE 1.7)

Официальный `pkgs.k8s.io` может быть недоступен или запрещён политикой. Порядок:

1. Скачать `.deb` kubelet/kubeadm/kubectl **1.29.x** на машине с интернетом.
2. Перенести на ноды и установить:

```bash
dpkg -i kubelet_*.deb kubeadm_*.deb kubectl_*.deb kubernetes-cni_*.deb cri-tools_*.deb || apt-get -f install -y
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet
```

Либо подключить внутренний зеркальный apt-репозиторий Kubernetes.

---

## B4–B5. kubeadm init / join / Calico

Команды **идентичны** разделу A4–A5 (те же IP, CIDR, labels). Отличия только в ОС-подготовке выше.

```bash
# на k8s-indexer
kubeadm init \
  --apiserver-advertise-address=10.10.10.11 \
  --pod-network-cidr=192.168.0.0/16 \
  --control-plane-endpoint=10.10.10.11:6443

mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

kubectl taint nodes k8s-indexer node-role.kubernetes.io/control-plane- || true
kubectl label node k8s-indexer role=indexer --overwrite
# join + labels на остальных нодах — как в A4

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml
# в закрытом контуре: kubectl apply -f calico.yaml из локальной копии
```

Особенность 1.7: ядро старше — если Calico eBPF/современные фичи не поднимаются, используйте **VXLAN** (дефолт в манифесте) и не включайте eBPF.

---

# Часть C. Astra Linux SE 1.8

Astra Linux SE **1.8** — Debian-based (~Debian 12 Bookworm). Установка ближе к современному Debian, пакеты новее, чем в 1.7.

## C1. Подготовка ОС (на всех 3 ВМ)

```bash
hostnamectl set-hostname k8s-indexer   # или k8s-manager / k8s-dashboard

cat >/etc/hosts <<'EOF'
127.0.0.1   localhost
10.10.10.11 k8s-indexer
10.10.10.12 k8s-manager
10.10.10.13 k8s-dashboard
EOF

apt-get update
apt-get -y upgrade
apt-get -y install curl wget tar git ca-certificates apt-transport-https \
  gnupg lsb-release chrony conntrack iptables iproute2 socat ebtables ethtool
systemctl enable --now chrony

swapoff -a
sed -ri 's/.*swap.*/#&/' /etc/fstab

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

### C1.1. MAC / ЗПС на 1.8

Те же правила, что для 1.7: согласуйте с ИБ профиль для K8s-нод (containerd, kubelet, CNI, privileged pods для Calico/local-path). Без этого этап «Ready» часто недостижим.

### C1.2. Firewall

```bash
apt-get -y install ufw
ufw allow 22/tcp
ufw allow 6443/tcp
ufw allow 2379:2380/tcp
ufw allow 10250/tcp
ufw allow 179/tcp
ufw allow 4789/udp
ufw allow 1514/tcp
ufw allow 1515/tcp
ufw allow 443/tcp
ufw allow 30000:32767/tcp
ufw --force enable
```

### C1.3. Data-диски

Как в B1.6 (`ext4` или `xfs` при наличии пакета `xfsprogs`).

---

## C2. containerd (Astra SE 1.8)

```bash
apt-get -y install containerd
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# при необходимости отключить sandbox_image на внутренний pause-образ
systemctl enable --now containerd
ctr version
```

На 1.8 штатный containerd обычно достаточен для K8s 1.28–1.29. Если apt отдаёт слишком старую версию — ставьте из внутреннего зеркала Docker/containerd.

---

## C3. Kubernetes packages (Astra SE 1.8)

```bash
# при доступе к pkgs.k8s.io (или зеркалу):
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get -y install kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet
```

В закрытом контуре — `dpkg -i` локальных `.deb`, как в B3.

---

## C4–C5. init / join / Calico

Идентично A4–A5 / B4–B5.

---

# Часть D. Общие этапы Kubernetes → Wazuh (все ОС)

Выполнять после того, как `kubectl get nodes` показывает **3× Ready**.

## D1. StorageClass (local-path на data SSD)

Для production на выделенных дисках удобен **Rancher local-path-provisioner** с путём `/data/wazuh`.

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
```

Переопределить путь (пример ConfigMap):

```bash
kubectl -n local-path-storage edit configmap local-path-config
# в config.json выставить:
# "nodePathMap":[{"node":"DEFAULT_PATH_FOR_NON_LISTED_NODES","paths":["/data/wazuh"]}]
```

Либо создать StorageClass `wazuh-local-ssd`:

```yaml
# storage-class-wazuh.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: wazuh-local-ssd
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
```

```bash
kubectl apply -f storage-class-wazuh.yaml
kubectl get sc
```

> Альтернатива: вручную создать PV с `local.path` и `nodeAffinity` на `k8s-indexer` / `k8s-manager` (жёстче и предсказуемее для single-indexer 300 Gi).

Пример статических PV (рекомендуется для 100 агентов):

```yaml
# pv-wazuh.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-wazuh-indexer
spec:
  capacity:
    storage: 300Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: wazuh-local-ssd
  local:
    path: /data/wazuh/indexer
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: role
          operator: In
          values: ["indexer"]
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-wazuh-manager-master
spec:
  capacity:
    storage: 50Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: wazuh-local-ssd
  local:
    path: /data/wazuh/manager-master
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: role
          operator: In
          values: ["manager"]
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-wazuh-manager-worker
spec:
  capacity:
    storage: 50Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: wazuh-local-ssd
  local:
    path: /data/wazuh/manager-worker
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: role
          operator: In
          values: ["manager"]
```

```bash
kubectl apply -f pv-wazuh.yaml
```

---

## D2. LoadBalancer (MetalLB) или HAProxy

### Вариант 1: MetalLB (L2)

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Ready pods --all --timeout=180s
```

```yaml
# metallb-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: wazuh-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.10.10.20-10.10.10.20
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: wazuh-l2
  namespace: metallb-system
```

```bash
kubectl apply -f metallb-pool.yaml
```

### Вариант 2: внешний HAProxy на VIP `10.10.10.20`

Проксируйте:

- `1514` → NodePort `wazuh-workers` (или IP ноды manager + NodePort)
- `1515` → NodePort сервиса `wazuh` (master)
- `443` → NodePort dashboard / Ingress

Узнайте NodePort после деплоя: `kubectl get svc -n wazuh`.

---

## D3. Клонирование wazuh-kubernetes и сертификаты

На машине администратора (с `kubectl` к кластеру):

```bash
git clone https://github.com/wazuh/wazuh-kubernetes.git -b v4.14.7 --depth=1
cd wazuh-kubernetes
```

Сертификаты indexer:

```bash
bash wazuh/certs/indexer_cluster/generate_certs.sh
```

Сертификаты dashboard HTTP:

```bash
bash wazuh/certs/dashboard_http/generate_certs.sh
```

Нужен `openssl`. На РЕД ОС: `dnf -y install openssl`; на Astra: `apt-get -y install openssl`.

---

## D4. StorageClass в манифестах local-env

```bash
# посмотреть текущий provisioner
kubectl get sc

# отредактировать
vi envs/local-env/storage-class.yaml
# выставить storageClassName / provisioner под wazuh-local-ssd
# либо удалить создание SC из kustomization и использовать уже созданный wazuh-local-ssd
```

В kustomize-патчах/`wazuh` манифестах замените `storageClassName` PVC на `wazuh-local-ssd`.

---

## D5. Production resources для 100 агентов (обязательно)

Дефолтные лимиты overlay (1 CPU / 2 Gi / 10 Gi на indexer) **не использовать**. Задайте:

| Компонент | replicas | CPU lim | RAM lim | PVC | nodeSelector |
|---|---:|---|---|---|---|
| manager-master | 1 | 4 | 8 Gi | 50 Gi | `role=manager` |
| manager-worker | **1** | 4 | 8 Gi | 50 Gi | `role=manager` |
| indexer | **1** | 4 | 16 Gi | **300 Gi** | `role=indexer` |
| dashboard | 1 | 1 | 2 Gi | — | `role=dashboard` |

Практически:

1. В `envs/local-env/` (или своих overlays) уменьшите workers с 2 → **1**.
2. Уменьшите indexer с 3 → **1** (compact).
3. Пропишите `resources.requests/limits` и размеры PVC.
4. Для indexer добавьте env/JVM: heap **8g** (`OPENSEARCH_JAVA_OPTS=-Xms8g -Xmx8g` или аналог в манифесте образа).
5. Добавьте `nodeSelector` / `affinity` по `role`.
6. Anti-affinity для indexer оставьте (на 1 реплике не критично, но полезно при будущем HA).

Пример фрагмента патча indexer:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: wazuh-indexer
spec:
  replicas: 1
  template:
    spec:
      nodeSelector:
        role: indexer
      containers:
      - name: wazuh-indexer
        resources:
          requests:
            cpu: "2"
            memory: 8Gi
          limits:
            cpu: "4"
            memory: 16Gi
        env:
        - name: OPENSEARCH_JAVA_OPTS
          value: "-Xms8g -Xmx8g"
  volumeClaimTemplates:
  - metadata:
      name: wazuh-indexer
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: wazuh-local-ssd
      resources:
        requests:
          storage: 300Gi
```

Аналогично для master/worker (PVC 50Gi, limits 4 CPU / 8Gi, `role=manager`) и dashboard (`role=dashboard`, 1 CPU / 2Gi).

Retention 90 дней настраивается ILM/политиками индексов после старта (Dashboard → Indexer management / шаблоны Wazuh). Базовый ориентир диска уже заложен в PVC 300 Gi.

---

## D6. Apply манифестов

```bash
kubectl apply -k envs/local-env/
```

Ожидание готовности:

```bash
kubectl get ns | grep wazuh
kubectl get pods -n wazuh -o wide -w
kubectl get statefulsets -n wazuh
kubectl get deploy -n wazuh
kubectl get pvc -n wazuh
kubectl get svc -n wazuh
```

Ожидаемо:

```
wazuh-indexer-0            1/1  Running   ...  k8s-indexer
wazuh-manager-master-0     1/1  Running   ...  k8s-manager
wazuh-manager-worker-0     1/1  Running   ...  k8s-manager
wazuh-dashboard-...        1/1  Running   ...  k8s-dashboard
```

Пароль enrollment:

```bash
kubectl exec -it wazuh-manager-master-0 -n wazuh -- cat /var/ossec/etc/authd.pass
```

Пароль dashboard (из документации/secret репозитория; часто меняют после первого входа):

```bash
kubectl get secrets -n wazuh
# смотрите secret с credentials dashboard / indexer admin
```

---

## D7. Экспорт сервисов наружу

Проверьте EXTERNAL-IP (MetalLB) или назначьте NodePort:

```bash
kubectl get svc -n wazuh
```

| Сервис | Порт | Для агентов / пользователей |
|---|---|---|
| `wazuh-workers` | 1514 | Manager IP (events) |
| `wazuh` | 1515 | Registration server |
| `dashboard` | 443/5601 | UI (через Ingress лучше на 443) |

Пример Ingress для dashboard (если стоит nginx-ingress):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wazuh-dashboard
  namespace: wazuh
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - host: wazuh.example.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: dashboard
            port:
              number: 5601
```

DNS `wazuh.example.local` → VIP `10.10.10.20`.

---

## D8. Проверка здоровья

```bash
# ноды и поды
kubectl get nodes -o wide
kubectl get pods -n wazuh -o wide

# логи
kubectl logs -n wazuh wazuh-manager-master-0 --tail=100
kubectl logs -n wazuh wazuh-manager-worker-0 --tail=100
kubectl logs -n wazuh wazuh-indexer-0 --tail=100
kubectl logs -n wazuh deploy/wazuh-dashboard --tail=100

# indexer
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u admin:<PASSWORD> https://localhost:9200/_cluster/health?pretty

# менеджер: очередь/дропы (после появления нагрузки)
kubectl exec -n wazuh wazuh-manager-worker-0 -- /var/ossec/bin/wazuh-control status
```

Сигналы перегрузки (мониторить после подключения агентов):

- `events_dropped` — analysisd
- `discarded_count` — remoted  

При росте — добавить worker (и при необходимости 2–3 indexer по HA-плану из architecture-дока).

---

## D9. Подключение агентов (до 100)

На агенте (Linux-пример):

```bash
export WAZUH_MANAGER='10.10.10.20'          # VIP сервиса workers :1514
export WAZUH_REGISTRATION_SERVER='10.10.10.20'  # VIP :1515
export WAZUH_REGISTRATION_PASSWORD='<authd.pass>'
# установка пакета агента той же major-версии, что менеджер (4.14.x)
# ... установка deb/rpm агента ...
systemctl enable --now wazuh-agent
```

Windows/macOS — по [официальной инструкции агента](https://documentation.wazuh.com), те же `MANAGER` / `REGISTRATION_SERVER` = VIP.

Проверка в UI: **Agents** → статус Active.

Сетевые устройства (~5% парка) — через syslog/agentless по документации Wazuh (не считают «полноценный» agent enrollment, но место на диске indexer заложено как network 7.4 GB/90d).

---

## D10. Базовая hardening-настройка после установки

1. Сменить пароли `admin` indexer и пользователя dashboard.
2. Включить TLS на внешнем Ingress (корпоративный сертификат).
3. Ограничить Source IP на LB `:1514`/`:1515` сетями агентов.
4. Настроить ILM/retention **90 дней** для индексов алертов.
5. Бэкап PVC indexer (snapshots в S3/NFS или volume snapshot).
6. Мониторинг PVC usage (>70% → расширять диск / HA).
7. Не хранить `admin` ключи в git; Secrets — из sealed-secrets/Vault.

---

# Часть E. Сводные отличия ОС

| Шаг | РЕД ОС 8 | Astra SE 1.7 | Astra SE 1.8 |
|---|---|---|---|
| Пакеты | `dnf` | `apt` (старее) | `apt` (новее, ~Debian 12) |
| containerd | docker-ce.repo / зеркало | часто только из зеркала, проверить версию ≥1.6 | обычно из apt / зеркала |
| Firewall | `firewalld` | `ufw`/iptables | `ufw`/iptables |
| MAC/SELinux | SELinux Enforcing | PARSEC/ЗПС — согласовать с ИБ | PARSEC/ЗПС — согласовать с ИБ |
| FS data | `xfs` предпочтительно | `ext4` | `ext4`/`xfs` |
| kube packages | rpm pkgs.k8s.io / зеркало | чаще offline `.deb` | apt pkgs.k8s.io / `.deb` |
| Calico | VXLAN OK | VXLAN; eBPF осторожно | VXLAN OK |
| Дальше (Wazuh) | **одинаково** (часть D) | **одинаково** | **одинаково** |

---

# Часть F. Чеклист приёмки (100 агентов)

- [ ] 3 ноды Ready, labels `role=indexer|manager|dashboard`
- [ ] `vm.max_map_count=262144` на всех нодах
- [ ] PVC: indexer 300Gi Bound на `k8s-indexer`; master/worker 50Gi на `k8s-manager`
- [ ] 4 пода Running
- [ ] Heap indexer = 8g
- [ ] VIP отвечает на `:1514`, `:1515`, `:443`
- [ ] Dashboard открывается, логин сменён
- [ ] Тестовый агент Active
- [ ] Нет роста `events_dropped` / `discarded_count` на пиковой нагрузке
- [ ] Политика retention 90 дней применена
- [ ] Есть процедура бэкапа PVC indexer

---

# Часть G. Типовые проблемы

| Симптом | Что проверить |
|---|---|
| `indexer` CrashLoop, `max virtual memory areas` | `sysctl vm.max_map_count` |
| PVC Pending | PV/nodeAffinity, путь `/data/wazuh/...`, StorageClass |
| Pod Pending | nodeSelector `role=...`, ресурсы ноды |
| Agent не регистрируется | FW до VIP `:1515`, `authd.pass`, сервис `wazuh` |
| Agent зарегистрирован, но No connection | VIP `:1514` → worker, LB backend |
| На Astra: CreateContainerError | MAC/ЗПС, AppArmor, права на `/data` |
| На РЕД ОС: permission denied | SELinux audit (`ausearch`), контекст томов |
| Dashboard 502 | сервис `dashboard`, сертификаты, Ingress backend-protocol HTTPS |

---

## Ссылки

- Архитектура и sizing: [wazuh-kubernetes-architecture.md](wazuh-kubernetes-architecture.md)
- Официально: [Deploying Wazuh on Kubernetes](https://documentation.wazuh.com/current/deployment-options/deploying-with-kubernetes/index.html)
- Репозиторий: https://github.com/wazuh/wazuh-kubernetes
