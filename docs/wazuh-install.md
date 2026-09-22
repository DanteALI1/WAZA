# Установка и настройка Wazuh в Kubernetes

Полная поэтапная инструкция для сценария **до 100 агентов** (compact + ARCHIVE), с отдельными шагами ОС:

- **РЕД ОС 8**
- **Astra Linux SE 1.7**
- **Astra Linux SE 1.8**

Архитектура и жизненный цикл данных (90 дней → архив): [wazuh-architecture.md](wazuh-architecture.md).

Манифесты: `wazuh-kubernetes` **v4.14.7**. В закрытом контуре все URL замените на зеркала/офлайн-пакеты.

---

## 0. Что получите в итоге

| Параметр | Значение |
|---|---|
| Поды Wazuh | 1 master + 1 worker + 1 indexer + 1 dashboard |
| ВМ | 4: indexer(+CP), manager, dashboard, **archive** |
| HOT | алерты **90 дней** online на SSD |
| ARCHIVE | снимки **≥ 1 год** на NFS (или MinIO) |
| После 90 дней | индекс уходит из HOT **только после** успешного снимка → дальше Restore при необходимости |

**Без шагов ARCHIVE (часть F) через 90 дней данные просто удаляются.**

IP в примерах (замените):

| Хост | IP |
|---|---|
| `k8s-indexer` | 10.10.10.11 |
| `k8s-manager` | 10.10.10.12 |
| `k8s-dashboard` | 10.10.10.13 |
| `wazuh-archive` | 10.10.10.14 |
| VIP LB | 10.10.10.20 |

---

## 1. Целевые ресурсы ВМ

| ВМ | vCPU | RAM | OS | Data | Назначение |
|---|---:|---:|---:|---:|---|
| k8s-indexer | 8 | 32 Gi | 80 Gi | **300 Gi SSD** | indexer + control-plane; mount NFS `/mnt/snapshots` |
| k8s-manager | 8 | **24 Gi** | 80 Gi | 100 Gi SSD | master + worker |
| k8s-dashboard | 4 | 8 Gi | 60 Gi | — | dashboard + Ingress |
| wazuh-archive | 4 | 8 Gi | 60 Gi | **1 Ti** | NFS server (рекомендуется) или MinIO |

Метки K8s: `role=indexer|manager|dashboard`.

---

# Часть A. РЕД ОС 8 — подготовка нод K8s

Выполнять на `k8s-indexer`, `k8s-manager`, `k8s-dashboard` (не на archive — ему NFS, часть F).

### A1. Hostname и hosts

```bash
hostnamectl set-hostname k8s-indexer   # своё имя на каждой

cat >/etc/hosts <<'EOF'
127.0.0.1 localhost
10.10.10.11 k8s-indexer
10.10.10.12 k8s-manager
10.10.10.13 k8s-dashboard
10.10.10.14 wazuh-archive
EOF
```

### A2. Пакеты, время, swap

```bash
dnf -y update
dnf -y install curl wget tar git chrony yum-utils device-mapper-persistent-data \
  lvm2 ca-certificates conntrack-tools iptables iproute-tc socat ebtables ethtool \
  nfs-utils openssl
systemctl enable --now chronyd
swapoff -a
sed -ri 's/.*swap.*/#&/' /etc/fstab
```

### A3. Модули и sysctl (обязателен max_map_count)

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

### A4. SELinux и firewalld

```bash
getenforce   # Enforcing допустим; при CreateContainerError — смотреть audit

systemctl enable --now firewalld
firewall-cmd --permanent --add-port=6443/tcp
firewall-cmd --permanent --add-port=2379-2380/tcp
firewall-cmd --permanent --add-port=10250/tcp
firewall-cmd --permanent --add-port=179/tcp
firewall-cmd --permanent --add-port=4789/udp
firewall-cmd --permanent --add-port=1514/tcp
firewall-cmd --permanent --add-port=1515/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=30000-32767/tcp
firewall-cmd --permanent --add-service=nfs
firewall-cmd --permanent --add-service=rpc-bind
firewall-cmd --permanent --add-service=mountd
firewall-cmd --reload
```

### A5. Data SSD

```bash
# /dev/sdb — пример
mkfs.xfs -f /dev/sdb
mkdir -p /data/wazuh
UUID=$(blkid -s UUID -o value /dev/sdb)
echo "UUID=${UUID} /data/wazuh xfs defaults,noatime 0 0" >>/etc/fstab
mount -a
mkdir -p /data/wazuh/indexer /data/wazuh/manager-master /data/wazuh/manager-worker
```

На indexer дополнительно точка для снимков (после NFS):

```bash
mkdir -p /mnt/snapshots
```

### A6. containerd

```bash
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
# или внутреннее зеркало
dnf -y install containerd.io
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
```

### A7. kubeadm / kubelet / kubectl

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

---

# Часть B. Astra Linux SE 1.7 — подготовка нод K8s

### B1. База

```bash
hostnamectl set-hostname k8s-indexer
# /etc/hosts — как в A1

apt-get update && apt-get -y upgrade
apt-get -y install curl wget tar git ca-certificates apt-transport-https gnupg \
  lsb-release chrony conntrack iptables iproute2 socat ebtables ethtool \
  nfs-common openssl
systemctl enable --now chrony
swapoff -a && sed -ri 's/.*swap.*/#&/' /etc/fstab
```

Sysctl/modules — **как A3**.

### B2. MAC / ЗПС

На SE контейнеры часто блокируются политикой. До kubeadm согласуйте с ИБ профиль нод (containerd, kubelet, privileged CNI, NFS mount). Иначе типичны `NotReady` / `CreateContainerError`.

### B3. Firewall (ufw)

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
ufw allow 2049/tcp
ufw --force enable
```

### B4. Диск data

```bash
mkfs.ext4 -F /dev/sdb
mkdir -p /data/wazuh
UUID=$(blkid -s UUID -o value /dev/sdb)
echo "UUID=${UUID} /data/wazuh ext4 defaults,noatime 0 0" >>/etc/fstab
mount -a
mkdir -p /data/wazuh/{indexer,manager-master,manager-worker} /mnt/snapshots
```

### B5. containerd и Kubernetes

```bash
apt-get -y install containerd
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
# Нужен containerd ≥1.6; иначе пакет из внутреннего artifactory
```

Kube packages чаще **offline**:

```bash
dpkg -i kubelet_*.deb kubeadm_*.deb kubectl_*.deb kubernetes-tools_*.deb kubernetes-cni_*.deb
apt-get -f install -y
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet
```

Calico: только VXLAN (eBPF на старом ядре 1.7 не включать).

---

# Часть C. Astra Linux SE 1.8 — подготовка нод K8s

Повторите B1–B4 (MAC/ЗПС тоже актуален). Пакеты новее (~Debian 12).

```bash
apt-get -y install containerd
# systemd cgroup — как выше

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get -y install kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet
```

В закрытом контуре — те же offline `.deb`, что в B5.

---

# Часть D. Кластер Kubernetes (все ОС)

### D1. init (только k8s-indexer)

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

### D2. join + labels

На manager и dashboard:

```bash
kubeadm join 10.10.10.11:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>
```

На CP:

```bash
kubectl taint nodes k8s-indexer node-role.kubernetes.io/control-plane- || true
kubectl label node k8s-indexer   role=indexer --overwrite
kubectl label node k8s-manager   role=manager --overwrite
kubectl label node k8s-dashboard role=dashboard --overwrite
```

### D3. Calico

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml
# офлайн: из локального файла
kubectl get nodes   # 3× Ready
```

### D4. Storage (local PV на SSD)

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
```

Предпочтительнее **статические PV** (предсказуемый узел):

```yaml
# pv-wazuh.yaml
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
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: wazuh-local-ssd }
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
```

```bash
kubectl apply -f pv-wazuh.yaml
```

### D5. MetalLB (VIP)

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Ready pods --all --timeout=180s
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

Альтернатива: внешний HAProxy на VIP → NodePorts сервисов Wazuh.

---

# Часть E. Развёртывание Wazuh (все ОС)

### E1. Репозиторий и сертификаты

```bash
git clone https://github.com/wazuh/wazuh-kubernetes.git -b v4.14.7 --depth=1
cd wazuh-kubernetes
bash wazuh/certs/indexer_cluster/generate_certs.sh
bash wazuh/certs/dashboard_http/generate_certs.sh
```

### E2. Production patches (100 агентов)

Обязательно изменить relative к дефолту:

| Параметр | Значение |
|---|---|
| indexer replicas | **1** |
| worker replicas | **1** |
| indexer PVC | **300Gi**, SC `wazuh-local-ssd` |
| master/worker PVC | **50Gi** |
| master lim | **2 CPU / 4 Gi** |
| worker lim | **4 CPU / 8 Gi** |
| indexer lim | **4 CPU / 24 Gi**, `OPENSEARCH_JAVA_OPTS=-Xms8g -Xmx8g` |
| dashboard lim | **2 CPU / 4 Gi** |
| nodeSelector | role=indexer\|manager\|dashboard |

Пример патча indexer:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: wazuh-indexer }
spec:
  replicas: 1
  template:
    spec:
      nodeSelector: { role: indexer }
      containers:
      - name: wazuh-indexer
        resources:
          requests: { cpu: "2", memory: 12Gi }
          limits:   { cpu: "4", memory: 24Gi }
        env:
        - { name: OPENSEARCH_JAVA_OPTS, value: "-Xms8g -Xmx8g" }
  volumeClaimTemplates:
  - metadata: { name: wazuh-indexer }
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: wazuh-local-ssd
      resources: { requests: { storage: 300Gi } }
```

В `envs/local-env/storage-class.yaml` / kustomization — согласовать SC с `wazuh-local-ssd`, не создавать конфликтующий microk8s SC.

### E3. Apply

```bash
kubectl apply -k envs/local-env/
kubectl get pods -n wazuh -o wide -w
kubectl get pvc -n wazuh
kubectl get svc -n wazuh
```

Ожидание: 4 пода Running на нужных нодах.

```bash
kubectl exec -it -n wazuh wazuh-manager-master-0 -- cat /var/ossec/etc/authd.pass
```

Сменить пароли admin indexer / dashboard сразу после первого входа.

### E4. Ingress dashboard (опционально)

Backend часто HTTPS (порт сервиса dashboard — смотрите `kubectl get svc -n wazuh`). DNS → VIP.

### E5. Выключить дорогой archives-индекс

Убедитесь, что Filebeat **не** пишет полный `wazuh-archives-*` (или ISM delete для archives = 7 дней max). Иначе диск HOT не совпадёт с расчётом алертов.

---

# Часть F. ARCHIVE — куда уходят события после 90 дней

Без этой части ISM delete = **безвозвратная потеря**.

Рекомендуемый вариант: **NFS** (как в официальном [Migrating Wazuh indices](https://documentation.wazuh.com/current/user-manual/wazuh-indexer/migrating-wazuh-indices.html)).

## F1. ВМ wazuh-archive (РЕД ОС 8)

```bash
hostnamectl set-hostname wazuh-archive
# hosts как выше

dnf -y install nfs-utils
mkfs.xfs -f /dev/sdb    # 1 Ti
mkdir -p /mnt/snapshots
UUID=$(blkid -s UUID -o value /dev/sdb)
echo "UUID=${UUID} /mnt/snapshots xfs defaults,noatime 0 0" >>/etc/fstab
mount -a

echo "/mnt/snapshots 10.10.10.0/24(rw,sync,no_root_squash,no_subtree_check)" >>/etc/exports
systemctl enable --now nfs-server
exportfs -a
firewall-cmd --permanent --add-service=nfs --add-service=rpc-bind --add-service=mountd
firewall-cmd --reload
```

## F1b. ВМ wazuh-archive (Astra 1.7 / 1.8)

```bash
apt-get -y install nfs-kernel-server
mkfs.ext4 -F /dev/sdb
mkdir -p /mnt/snapshots
# fstab + mount
echo "/mnt/snapshots 10.10.10.0/24(rw,sync,no_root_squash,no_subtree_check)" >>/etc/exports
exportfs -a
systemctl enable --now nfs-kernel-server
```

## F2. Mount NFS на ноде indexer (и во все indexer при HA)

На **хосте** `k8s-indexer` (hostPath в под):

```bash
# РЕД ОС: nfs-utils уже стоял; Astra: nfs-common
mount -t nfs 10.10.10.14:/mnt/snapshots /mnt/snapshots
echo "10.10.10.14:/mnt/snapshots /mnt/snapshots nfs defaults,_netdev 0 0" >>/etc/fstab
# UID пользователя indexer в контейнере — часто 1000; на NFS:
chown -R 1000:1000 /mnt/snapshots   # уточните id из пода
```

Проброс в StatefulSet indexer (patch):

```yaml
# фрагмент
spec:
  template:
    spec:
      containers:
      - name: wazuh-indexer
        volumeMounts:
        - name: snapshots
          mountPath: /mnt/snapshots
      volumes:
      - name: snapshots
        hostPath:
          path: /mnt/snapshots
          type: Directory
```

В конфигурации OpenSearch/`opensearch.yml` образа должен быть:

```yaml
path.repo: ["/mnt/snapshots"]
```

Если параметр не прокинут — добавьте через configmap/env манифеста wazuh-kubernetes (обязательная проверка после старта).

Перезапуск пода indexer после mount:

```bash
kubectl delete pod -n wazuh wazuh-indexer-0
# STS поднимет заново
```

## F3. Зарегистрировать snapshot repository

Из Dashboard: **Indexer management → Snapshot Management → Repositories → Create**

- Type: **Shared file system**
- Location: `/mnt/snapshots`
- Name: `wazuh-archive-repo`

Или API:

```bash
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u admin:<PASS> \
  -H 'Content-Type: application/json' \
  -X PUT 'https://localhost:9200/_snapshot/wazuh-archive-repo' \
  -d '{"type":"fs","settings":{"location":"/mnt/snapshots","compress":true}}'
```

## F4. Политика снимков (ежедневно)

Dashboard → **Snapshot Management → Snapshot policies** (или SM Policies):

- Имя: `daily-alerts`
- Repository: `wazuh-archive-repo`
- Indices: `wazuh-alerts-*`
- Include cluster state: **yes**
- Schedule: `0 2 * * *` (02:00)
- Retention снимков на ARCHIVE: например **365 дней** (удалять snapshot старше года — это и есть «архивный retention»)

Проверка:

```bash
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u admin:<PASS> \
  'https://localhost:9200/_snapshot/wazuh-archive-repo/_all?pretty' | head
```

Алерт: если за 36 часов нет нового SUCCESS snapshot — pager/mail (внешний мониторинг или Watcher).

## F5. ISM: HOT 90 дней → delete

Цель: индексы алертов старше 90 суток **удаляются с SSD**, опираясь на то, что дневные снимки уже на NFS.

Dashboard → **Indexer management → Index Management → State management policies**:

Пример политики (адаптируйте под имена индексов вашей версии):

```json
{
  "policy": {
    "description": "HOT 90d then delete (archive via snapshots)",
    "default_state": "hot",
    "states": [
      {
        "name": "hot",
        "actions": [],
        "transitions": [
          {
            "state_name": "delete",
            "conditions": { "min_index_age": "90d" }
          }
        ]
      },
      {
        "name": "delete",
        "actions": [{ "delete": {} }],
        "transitions": []
      }
    ],
    "ism_template": [{
      "index_patterns": ["wazuh-alerts-*"],
      "priority": 100
    }]
  }
}
```

**Порядок внедрения (важно):**

1. Сначала 7–14 дней стабильные daily snapshots.
2. Потом включить ISM delete.
3. Раз в квартал — учебный Restore одного старого индекса на стенде/в отдельном namespace.

Опционально усиление: за 2 дня до delete отдельный snapshot только этого индекса (SM policy по age) — если политика SM это поддерживает в вашей версии OpenSearch.

## F6. Процедура Restore (расследование инцидента >90 дней)

1. Dashboard → Snapshot Management → Snapshots → выбрать снимок → **Restore**.
2. Indices: нужный `wazuh-alerts-YYYY.MM.DD` (или паттерн).
3. Не держать восстановленное на HOT дольше расследования.
4. После — delete восстановленного индекса.

Документируйте RTO: для 300 Gi full repo restore может занять часы — для точечного индекса обычно минуты–десятки минут.

## F7. Альтернатива ARCHIVE: MinIO (S3)

Если NFS нельзя:

1. Поднять MinIO на `wazuh-archive` (диск 1 Ti), bucket `wazuh-snapshots`.
2. Установить OpenSearch repository-s3 plugin **в образ/под indexer** (если не встроен) — проверьте совместимость образа Wazuh.
3. Repository type **S3**, endpoint MinIO, keys в Kubernetes Secret.
4. Те же daily policies + ISM.

Для РЕД ОС/Astra в закрытом контуре NFS обычно проще (меньше plugins).

---

# Часть G. Агенты, сеть, приёмка

### G1. Агенты

```bash
export WAZUH_MANAGER='10.10.10.20'              # :1514 workers
export WAZUH_REGISTRATION_SERVER='10.10.10.20'  # :1515 master
export WAZUH_REGISTRATION_PASSWORD='<authd.pass>'
# установить агент той же major-версии 4.14.x
```

### G2. Чеклист

- [ ] 3 K8s-ноды Ready + labels
- [ ] `vm.max_map_count=262144`
- [ ] 4 пода Wazuh Running; PVC Bound
- [ ] VIP :1514/:1515/:443
- [ ] NFS смонтирован, `path.repo` активен
- [ ] Repository `wazuh-archive-repo` зелёный
- [ ] Есть успешный тестовый snapshot
- [ ] ISM policy на `wazuh-alerts-*` (после периода обкатки снимков)
- [ ] Тестовый Restore одного индекса
- [ ] Мониторинг: disk HOT, disk ARCHIVE, snapshot SUCCESS, `events_dropped=0`, `discarded_count=0`
- [ ] Пароли сменены; `wazuh-archives-*` не раздувает диск

### G3. Типовые проблемы

| Симптом | Причина / действие |
|---|---|
| Indexer про max virtual memory | `sysctl vm.max_map_count` |
| Snapshot FAIL / repository verification | NFS mount, права 1000:1000, `path.repo`, firewall 2049 |
| PVC Pending | PV nodeAffinity / путь `/data/wazuh/...` |
| Agent no connection | VIP 1514/1515, authd.pass |
| HOT растёт >90d | ISM не применён / индексы не матчят pattern |
| ARCHIVE полный | чистить snapshot retention / расширить 1 Ti |
| Astra CreateContainerError | MAC/ЗПС |
| РЕД ОС permission | SELinux audit на volumes/NFS |

---

# Часть H. Отличия ОС (сводка)

| Шаг | РЕД ОС 8 | Astra 1.7 | Astra 1.8 |
|---|---|---|---|
| Пакеты | dnf | apt (старше) | apt (~Debian 12) |
| FS data | xfs | ext4 | ext4/xfs |
| Firewall | firewalld | ufw | ufw |
| MAC | SELinux | ЗПС/PARSEC | ЗПС/PARSEC |
| NFS server | nfs-utils | nfs-kernel-server | nfs-kernel-server |
| NFS client | nfs-utils | nfs-common | nfs-common |
| K8s+Wazuh+ARCHIVE | далее одинаково | одинаково | одинаково |

---

# Часть I. Если масштабируете до 1000 агентов

См. [wazuh-architecture.md](wazuh-architecture.md) §8: 3 indexer × 2 Ti, 3 workers, LB обязателен, ARCHIVE **8–10 Ti**, NFS mount на **каждой** indexer-ноде к одному export (или MinIO). ISM/snapshot политики те же, меняются только размеры и число реплик.

---

## Ссылки

- Архитектура: [wazuh-architecture.md](wazuh-architecture.md)
- Snapshots / NFS: https://documentation.wazuh.com/current/user-manual/wazuh-indexer/migrating-wazuh-indices.html
- Deploy on Kubernetes: https://documentation.wazuh.com/current/deployment-options/deploying-with-kubernetes/index.html
