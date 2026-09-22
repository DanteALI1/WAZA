# Архитектура Wazuh в Kubernetes на VMware ESXi 7

Production-контур для **до 100** и **до 1000** агентов:

- создание ВМ в **ESXi 7** (параметры hardware);
- разметка дисков при установке ОС (РЕД ОС 8 / Astra SE 1.7 / 1.8);
- HOT 90 дней + отдельный сервер **ARCHIVE**;
- ежедневная архивация снимков и **просмотр старых данных в Wazuh Dashboard** через Restore.

Установка: [wazuh-install.md](wazuh-install.md).  
Манифесты: Wazuh **4.14.x** (`wazuh-kubernetes` `v4.14.7`).

---

## 1. Жизненный цикл данных (обязательно понять)

```
Агенты → workers → Filebeat → Indexer HOT (SSD, поиск 0–90 дней)
                                      │
                         ежедневно 02:00 snapshot
                                      ▼
                         ARCHIVE-сервер (NFS, отдельная ВМ)
                         хранение снимков ≥ 1 год
                                      │
                         ISM: индекс старше 90d → delete с HOT
                                      │
              расследование: Restore snapshot → индекс снова в HOT
                           → смотрите в Dashboard (Discover / Security events)
                           → после работы удалить восстановленный индекс
```

| Вопрос | Ответ |
|---|---|
| Куда уходят события через 90 дней сами? | **Никуда.** Без ARCHIVE ISM их **удаляет навсегда**. |
| Архивация есть из коробки? | **Нет.** Нужен Snapshot Repository (NFS/`path.repo` — официальный путь Wazuh). |
| Как смотреть старое в Wazuh? | Только после **Restore** снимка в indexer → UI как обычно. |
| `wazuh-archives-*`? | Другое: поток «все события». В этой архитектуре **выключен** (съест диск). |

---

## 2. Допущения

- Парк: ~70% WS / ~25% servers / ~5% network
- HOT retention алертов: **90 дней**
- ARCHIVE retention снимков: **365 дней** (опционально 3 года)
- Hypervisor: **VMware ESXi 7.x** (+ vCenter по возможности)
- ОС гостей: РЕД ОС 8 **или** Astra Linux SE 1.7 / 1.8
- Datastore HOT-дисков: **SSD/NVMe**; ARCHIVE data: SSD или HDD
- Sizing диска indexer (GB/агент/90d): WS 1.5 / server 3.7 / network 7.4
- Масштаб manager — workers; сигналы: `events_dropped`, `discarded_count`
- Heap indexer = половина целевого RAM пода

---

## 3. Логическая топология (100 агентов — рекомендуемый старт)

| ВМ | Роль | vCPU | RAM | Диск OS (vmdk) | Диск DATA (vmdk) | Datastore тип |
|---|---|---:|---:|---:|---:|---|
| `k8s-indexer` | K8s CP + indexer | 8 | 32 Gi | **80 Gi** | **300 Gi** | SSD |
| `k8s-manager` | master+worker pods | 8 | 24 Gi | **80 Gi** | **100 Gi** | SSD |
| `k8s-dashboard` | dashboard + Ingress | 4 | 8 Gi | **60 Gi** | — | SSD/any |
| `wazuh-archive` | NFS snapshots | 4 | 8 Gi | **60 Gi** | **1024 Gi (1 Ti)** | HDD OK |

VIP LB (MetalLB/HAProxy): `:1514`, `:1515`, `:443`.  
Сеть ARCHIVE: только с IP indexer (NFS 2049).

Для **1000 агентов** — §12; ARCHIVE data **8–10 Ti**.

---

## 4. Создание ВМ в ESXi 7 — общие настройки

Делать для **каждой** ВМ, затем отличия по ролям (§5).

### 4.1. Мастер создания ВМ (New Virtual Machine)

| Параметр | Значение | Почему |
|---|---|---|
| Creation type | Create a new virtual machine | — |
| Name | как в таблице (`k8s-indexer` …) | DNS/hosts |
| Compatibility | **ESXi 7.0 and later** | аппаратная версия 17+ |
| Guest OS family | Linux | — |
| Guest OS version | **Other 4.x or later Linux (64-bit)** или ближайший RHEL/Debian 64-bit | РЕД ОС≈RHEL; Astra≈Debian. Если есть точный профиль — выбрать его |
| Firmware | **EFI** | современный boot; для Astra/РЕД ОС обычно EFI |
| Secure Boot | **Disabled** (пока) | проще для kube/NFS; включать только после проверки цепочки |

### 4.2. CPU

| Параметр | Значение | Почему |
|---|---|---|
| CPU | см. роль (§5) | — |
| Cores per socket | **1** (или = числу vCPU, без NUMA-сюрпризов на малых ВМ) | предсказуемый scheduling |
| CPU Hot Plug | **Disabled** | стабильность K8s/OpenSearch |
| Hardware virtualization (VHV/VT-x exposure) | **Disabled** | nested KVM не нужен |
| Latency Sensitivity | Normal; для indexer можно **High** если лицензия/кластер позволяет | меньше jitter I/O |

Резервация CPU (Reservation): для indexer/manager желательно **≥50%** номинала в production; на archive — не обязательно.

### 4.3. Memory

| Параметр | Значение |
|---|---|
| Memory | по роли |
| Reserve all guest memory (All locked) | **рекомендуется для indexer** (и желательно manager) |
| Memory Hot Plug | **Disabled** |

Без reservation ESXi при overcommit начнёт ballooning → GC/OOM у indexer.

### 4.4. SCSI / Controllers / Disks

| Параметр | Значение | Почему |
|---|---|---|
| SCSI Controller 0 | **VMware Paravirtual (PVSCSI)** | выше IOPS, меньше CPU |
| Hard disk 1 (OS) | размер по роли, **Thin** или Thick Lazy | ОС |
| Hard disk 2 (DATA) | размер по роли (если есть) | отдельный vmdk — обязательно отдельно от OS |
| Disk Provisioning DATA (indexer/manager) | **Thick Provision Eager Zeroed** | стабильный latency для OpenSearch/PVC |
| Disk Provisioning ARCHIVE data | Thick Lazy или Thin | холодные снимки |
| Sharing | No sharing | — |
| Disk Mode | Dependent | обычные snapshots ВМ не путать со snapshot indexer |
| Controller location | SCSI Controller 0 | оба диска на PVSCSI |

> Не ставить OS+DATA одним диском: проще расширять DATA, проще LVM/mount, меньше риск забить root.

Virtual Device Node: Disk1 = `SCSI(0:0)`, Disk2 = `SCSI(0:1)`.

### 4.5. Network

| Параметр | Значение |
|---|---|
| Adapter type | **VMXNET 3** |
| Network | port group: management/K8s (и отдельный PG для NFS, если сегментируете) |
| Connect at power on | Yes |

Рекомендация: 2 vNIC на indexer — `eth0` K8s/agents path, `eth1` только к ARCHIVE NFS (опционально, но правильно для ИБ).

### 4.6. Прочее

| Параметр | Значение |
|---|---|
| CD/DVD | Datastore ISO ОС, Connect at power on при установке |
| USB | не нужны |
| vTPM | по политике ИБ (Astra); для K8s не обязателен |
| VMware Tools / open-vm-tools | установить **после** ОС |
| Snapshots ВМ ESXi | **не держать** долго на indexer/manager (портят I/O); бэкап — через archive snapshots OpenSearch + бэкап ВМ по регламенту |

### 4.7. Anti-affinity (если vCenter)

Правила VM/Host: `k8s-indexer`, `k8s-manager`, `k8s-dashboard`, `wazuh-archive` — **на разных ESXi-хостах** по возможности. Два indexer (в HA) — никогда на одном хосте.

---

## 5. ESXi 7 — параметры по ролям (100 агентов)

### 5.1. `k8s-indexer`

| Параметр | Значение |
|---|---|
| vCPU | **8** |
| RAM | **32 Gi**, Reserve all guest memory = **Yes** |
| Disk1 OS | **80 Gi**, Thin/Lazy |
| Disk2 DATA | **300 Gi**, **Eager Zeroed**, datastore **SSD** |
| Latency Sensitivity | High (если доступно) |
| Сеть | VMXNET3; опционально 2-я NIC к NFS |

### 5.2. `k8s-manager`

| Параметр | Значение |
|---|---|
| vCPU | **8** |
| RAM | **24 Gi**, reservation ≥ 16 Gi |
| Disk1 OS | **80 Gi** |
| Disk2 DATA | **100 Gi**, Eager Zeroed, SSD |

### 5.3. `k8s-dashboard`

| Параметр | Значение |
|---|---|
| vCPU | **4** |
| RAM | **8 Gi** |
| Disk1 OS | **60 Gi** |
| Disk2 | нет |

### 5.4. `wazuh-archive` (отдельный сервер архивации)

| Параметр | Значение |
|---|---|
| vCPU | **4** |
| RAM | **8 Gi** |
| Disk1 OS | **60 Gi** |
| Disk2 DATA | **1024 Gi (1 Ti)**, Thick Lazy/Thin, datastore может быть **HDD** |
| Сеть | VMXNET3 в том же L2/L3, что indexer (или выделенный NFS VLAN) |
| Роль | **только NFS-сервер** (не член K8s) |
| Snapshots ESXi этой ВМ | по регламенту бэкапа (отдельно от OpenSearch snapshots) |

Почему отдельная ВМ: снимки индексов не должны жить на том же SSD/datastore, что HOT; потеря datastore indexer не должна стереть ARCHIVE.

---

## 6. Разделы при установке ОС

Правило: **swap не использовать** (K8s требует swapoff). На ARCHIVE swap тоже не нужен.

Схема ниже — для **ручной разметки** (Custom / Manual partitioning). Имена дисков: `sda` = OS vmdk, `sdb` = DATA vmdk (в ESXi могут быть `nvme0n1` — смотрите `lsblk`).

### 6.1. Общий шаблон OS-диска (`sda`, GPT + EFI)

| Точка монтирования | Размер | FS | Диск | Примечание |
|---|---:|---|---|---|
| `/boot/efi` | **600 MiB** | vfat (EFI System) | sda | обязательно при EFI |
| `/boot` | **1 GiB** | xfs (РЕД ОС) / ext4 (Astra) | sda | ядра |
| `/` | **остаток OS-диска** | xfs / ext4 | sda | root+var+usr |
| swap | **не создавать** | — | — | после установки `swapoff -a` |

Размеры OS-дисков:

| ВМ | OS vmdk | ≈ под `/` после EFI+boot |
|---|---:|---:|
| indexer / manager | 80 Gi | ~78 Gi |
| dashboard / archive | 60 Gi | ~58 Gi |

### 6.2. DATA-диск (`sdb`) — не в LVM с root

В установщике ОС: **не размечать sdb** (оставить пустым) **или** сразу одна partition + mount — проще разметить **после** установки (см. install). Архитектурно целевые mount:

| ВМ | Устройство | Размер | FS | Mount | Содержимое |
|---|---|---:|---|---|---|
| k8s-indexer | sdb1 | 300 Gi | **xfs** (РЕД) / **ext4** (Astra) | `/data/wazuh` | PVC indexer (`.../indexer`) |
| k8s-manager | sdb1 | 100 Gi | xfs/ext4 | `/data/wazuh` | `manager-master`, `manager-worker` |
| k8s-dashboard | — | — | — | — | — |
| wazuh-archive | sdb1 | **1 Ti** | xfs/ext4 | `/mnt/snapshots` | NFS export = snapshot repo |

Подкаталоги на indexer/manager после монтирования:

```
/data/wazuh/indexer
/data/wazuh/manager-master
/data/wazuh/manager-worker
```

### 6.3. РЕД ОС 8 vs Astra — отличия разметки

| | РЕД ОС 8 | Astra SE 1.7 / 1.8 |
|---|---|---|
| Установщик | Anaconda (как RHEL) | свой graphical/text (Debian-like) |
| FS по умолчанию | **xfs** на `/` и data | **ext4** |
| LVM | можно на `/`, но data лучше **без LVM** (простой partition) | то же |
| MAC/ЗПС | SELinux | согласовать исключения для K8s/NFS |

### 6.4. Почему так

- Отдельный DATA → расширение vmdk в ESXi без переразметки root.
- Eager Zeroed + xfs/ext4 noatime → предсказуемый I/O indexer.
- Нет swap → kubelet не конфликтует.
- ARCHIVE на отдельном mount `/mnt/snapshots` → совпадает с официальным `path.repo`.

---

## 7. Компоненты Wazuh / K8s

| Компонент | Kind | Порты |
|---|---|---|
| manager-master ×1 | STS | 1515, 55000, 1516 |
| manager-worker ×N | STS | 1514 → Filebeat → 9200 |
| indexer ×M | STS | 9200, 9300 + mount NFS repo |
| dashboard ×K | Deploy | 443 |
| **wazuh-archive** | ВМ NFS | 2049 (не pod) |

Поды 100 compact: master lim 2CPU/4Gi; worker 4/8; indexer 4/24 heap 8g PVC 300Gi; dashboard 2/4.

---

## 8. Сервер архивации — логика и настройки

### 8.1. Назначение

Хранить **OpenSearch/Wazuh indexer snapshots** (не «сырые» логи агентов). Это сжатые снимки индексов `wazuh-alerts-*` (+ cluster state).

### 8.2. ПО на ВМ

- ОС: та же линейка (РЕД ОС 8 или Astra)
- Пакеты: `nfs-utils` / `nfs-kernel-server`
- Службы: `nfs-server`, firewall только с сети indexer
- Export: `/mnt/snapshots` → CIDR indexer(ов)
- Опции export: `rw,sync,no_root_squash,no_subtree_check` (как в доке Wazuh; `no_root_squash` нужен для uid процесса indexer в контейнере — зафиксировать UID, обычно 1000)
- chrony обязателен (иначе расхождение времени ломает политики)

### 8.3. Ежедневная архивация — как сделать

1. На indexer: `path.repo: ["/mnt/snapshots"]`, NFS смонтирован с archive.
2. Зарегистрировать repository `wazuh-archive-repo` (type: shared file system).
3. **Snapshot Management Policy** (Dashboard или API):
   - schedule: `0 2 * * *` (каждый день 02:00);
   - indices: `wazuh-alerts-*`;
   - include cluster state: yes;
   - retention снимков: **365d** (удалять snapshot старше года на ARCHIVE).
4. Мониторинг: алерт, если >36 часов нет `SUCCESS`.
5. ISM на `wazuh-alerts-*`: `min_index_age: 90d` → `delete` (включать **после** обкатки снимков 7–14 дней).

Итог: каждый день на ARCHIVE появляются/обновляются снимки; через 90 дней HOT чистится; год истории лежит на NFS.

### 8.4. Как потом «достать и смотреть» в Wazuh

Снимки **не видны** в Discover, пока лежат только на NFS.

Пошагово:

1. Wazuh Dashboard → ☰ → **Indexer management** → **Snapshot Management** → **Snapshots**.
2. Найти снимок за нужную дату (или содержащий нужный `wazuh-alerts-YYYY.MM.DD`).
3. **Restore** → выбрать индексы → убрать конфликтующий prefix при необходимости.
4. Дождаться зелёного статуса индекса (`_cat/indices`).
5. **Discover** / **Threat Hunting** / **Security events** — выбрать index pattern `wazuh-alerts-*` и диапазон дат восстановленного периода.
6. После расследования: **удалить** восстановленный индекс с HOT (чтобы не забить 300 Gi).
7. Данные на ARCHIVE при этом **остаются** (пока не истечёт retention снимков).

Ограничения:

- Restore требует свободное место на HOT SSD (оценка ≈ размер индекса + запас).
- Нельзя «подключить ARCHIVE как read-only searchable» без restore (для searchable snapshots нужен другой класс хранилища/лицензий OpenSearch — в этом плане не используем).

### 8.5. Резервное копирование самого ARCHIVE

Раз в неделю: бэкап ВМ archive или `rsync`/`borg` каталога `/mnt/snapshots` на второй СХД. Иначе одна ВМ archive = SPOF истории.

---

## 9. Расчёт дисков HOT / ARCHIVE

```
HOT_primary_90d = N_ws×1.5 + N_srv×3.7 + N_net×7.4
HOT_single      = HOT_primary_90d × 1.25
ARCHIVE_1y      ≈ HOT_primary_90d × (365/90) × 0.85
```

| Сценарий | HOT primary | HOT PVC | ARCHIVE 1 год |
|---|---:|---:|---:|
| 100 агентов | 235 GB | **300 Gi** | **~1 Ti** |
| 1000 агентов | 2.3 Ti | 3×**2 Ti** | **~8–10 Ti** |

---

## 10. Сеть и порты

| Порт | Куда |
|---:|---|
| 1514 | LB → workers |
| 1515 | LB → master |
| 443 | UI |
| 6443 | K8s API |
| 2049 | ARCHIVE NFS ← только indexer |
| 9200/9300/1516/55000 | internal |

---

## 11. Когда масштабировать

| Сигнал | Действие |
|---|---|
| `events_dropped` / `discarded_count` > 0 | +worker (+ВМ) |
| HOT >70% | PVC↑ или проверить ISM |
| Snapshot FAIL | чинить NFS/archive немедленно |
| ARCHIVE >80% | расширить vmdk 1 Ti / чистить старые snapshots |
| Нужен HA | 3 indexer + 2 workers + anti-affinity ESXi |

---

## 12. Сценарий 1000 агентов (кратко)

| ВМ | vCPU / RAM | OS / DATA vmdk |
|---|---|---|
| Indexer ×3 | 16 / 64 | 120 Gi / **2 Ti SSD** Eager Zeroed |
| Master ×1 | 16 / 32 | 100 / 100 |
| Worker ×3 | 16 / 32 | 100 / 100 |
| Dashboard ×1 | 8 / 16 | 100 / — |
| Archive ×1 | 8 / 16 | 100 / **8–10 Ti** |
| LB :1514 | обязателен | — |

Разделы ОС — тот же шаблон §6; DATA mount тот же. NFS export монтируется на **каждый** indexer.

---

## 13. Сводка «рабочесть»

| Контур | Оценка |
|---|---|
| 100 + ESXi + ARCHIVE | **Рабочая production** |
| Без ARCHIVE при retention 90d | **Неприемлемо** (потеря данных) |
| 1000 HA + ARCHIVE | **Рабочая с запасом** |

---

## 14. Чеклист архитектуры

- [ ] 4 ВМ созданы в ESXi 7 с параметрами §4–§5
- [ ] PVSCSI, VMXNET3, EFI, DATA отдельным vmdk Eager Zeroed (HOT)
- [ ] Разделы: EFI+boot+/, без swap; DATA → `/data/wazuh` или `/mnt/snapshots`
- [ ] Archive вне K8s, NFS только для indexer
- [ ] Daily snapshot 02:00 + retention 365d
- [ ] ISM 90d delete после обкатки снимков
- [ ] Процедура Restore → просмотр в Dashboard отработана
- [ ] Бэкап самой ВМ archive

Далее: [wazuh-install.md](wazuh-install.md).
