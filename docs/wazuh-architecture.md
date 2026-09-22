# Архитектура Wazuh в Kubernetes (полная)

Production-план для **до 100** и **до 1000** агентов, включая **жизненный цикл данных после 90 дней**.

Версия ориентира манифестов: Wazuh **4.14.x** (`wazuh-kubernetes` tag `v4.14.7`).

---

## 1. Ключевой принцип: куда деваются события через 90 дней

### 1.1. Что хранит indexer

| Индекс / поток | Содержимое | По умолчанию без политики |
|---|---|---|
| `wazuh-alerts-*` | Сработавшие правила (алерты) | Растут, пока диск не кончится |
| `wazuh-archives-*` | Все события (если включён archives в Filebeat) | Очень объёмно; **по умолчанию в этом плане выключено** |
| `wazuh-statistics-*`, мониторинг | Служебные метрики | Короткий retention |

Официальный sizing диска (GB/агент/90 дней) относится к **алертам в indexer**: WS 1.5 / server 3.7 / network 7.4.

### 1.2. Если «просто поставить 90 дней» и ничего больше

Индексы старше 90 суток удаляются политикой **ISM (Index State Management)** → данные **безвозвратно исчезают**.  
**Автоматического архива «куда-то на полку» у Wazuh нет**, пока вы сами не настроите **Snapshot Management** (официальный путь — NFS/`path.repo` или S3-совместимое хранилище).

### 1.3. Принятая в этой архитектуре модель (обязательная)

```
Агенты → Manager workers → Filebeat
                              ↓
                    Indexer HOT (SSD)
                    поиск online ≤ 90 дней
                              ↓
              ежедневный snapshot (+ снимок перед delete)
                              ↓
                    ARCHIVE (NFS или MinIO/S3)
                    холодное хранение N лет
                              ↓
              ISM delete индекса из HOT
                              ↓
         при расследовании: Restore snapshot → временный индекс → UI
```

| Этап | Срок (рекомендация) | Где | Доступ из Dashboard |
|---|---|---|---|
| **HOT** | 0–90 дней | PVC indexer, SSD | Да, сразу |
| **ARCHIVE** | 90 дней → **1 год** (минимум); опционально 3 года | Отдельная ВМ NFS или MinIO | Нет, пока не сделан Restore |
| **После ARCHIVE** | удаление снимков по политике | — | Нет |

**Итог:** через 90 дней события **не «уходят сами»** — они либо **удаляются**, либо (в нашем плане) **уже лежат в снимках на ARCHIVE**, а с HOT удаляются. Без ВМ/тома ARCHIVE схема с retention 90 дней = потеря истории.

---

## 2. Допущения

- Парк: ~70% workstations / ~25% servers / ~5% network
- Retention HOT (алерты): **90 дней**
- Retention ARCHIVE: **365 дней** (базовый контракт); параметр `ARCHIVE_YEARS` можно поставить 3
- Archives-индекс (`wazuh-archives-*`) **выключен** (иначе диск ×5–20)
- Sizing от APS/retention, не только от числа агентов
- Масштабирование manager — **workers**; сигналы: `events_dropped`, `discarded_count`
- Indexer: только SSD; heap = ½ целевого RAM пода (`-Xms=-Xmx`)
- Не использовать lab-лимиты wazuh-kubernetes EKS overlay (1 CPU / 2 Gi / 10 Gi)

---

## 3. Компоненты

| Компонент | Kind | Роль | Порты |
|---|---|---|---|
| `wazuh-manager-master` | STS ×1 | authd, API, cluster | 1515, 55000, 1516 |
| `wazuh-manager-worker` | STS ×N | events, analysisd, Filebeat | 1514 → 9200 |
| `wazuh-indexer` | STS ×M | HOT хранение/поиск | 9200, 9300 |
| `wazuh-dashboard` | Deploy ×K | UI | 443/5601 |
| **archive-store** | ВМ NFS **или** MinIO в K8s/ВМ | снимки индексов | 2049 (NFS) / 9000 (S3) |
| LB / Ingress | — | агенты и UI | 1514, 1515, 443 |

```
[Agents] :1515→ LB → master
[Agents] :1514→ LB → workers → Filebeat → indexer :9200
[Users]  :443 → Ingress → dashboard → API :55000 + indexer
[Indexer] snapshot → ARCHIVE (NFS/MinIO)
```

Anti-affinity: не два indexer на одну ВМ; managers разносить по возможности.

---

## 4. Политика данных (ISM + Snapshot) — детально

### 4.1. Расписание снимков

| Тип | Когда | Что | Зачем |
|---|---|---|---|
| Incremental / indices | **ежедневно** 02:00 | `wazuh-alerts-*` (+ cluster state) | не потерять сутки при аварии диска HOT |
| Pre-delete | в ISM перед удалением (или отдельный job за 1–2 дня до delete) | индексы, которым → 90d | гарантия, что уходящий с HOT уже в ARCHIVE |
| Проверка | ежедневно | `GET _snapshot/.../_all` + алерт если fail | иначе «думали что архив есть» |

### 4.2. ISM (логика)

1. Index rollover / daily indices (как принято в Wazuh).
2. Состояние **hot**: 0–90 дней, searchable.
3. Перед удалением: убедиться, что индекс включён в успешный snapshot (SM policy / external cron).
4. Состояние **delete**: удалить индекс с HOT.

> OpenSearch ISM сам по себе **не копирует** данные на NFS. Сначала Snapshot Management (или `_snapshot` API), потом delete.

### 4.3. Восстановление

1. Indexer Management → Snapshot Management → Restore.
2. Восстановить в имя без конфликта (или убрать `restored_` prefix по доке Wazuh).
3. После расследования — снова удалить восстановленный индекс с HOT (чтобы не съесть SSD).

### 4.4. Чего нельзя делать

- Считать PVC indexer «архивом» и копить >90 дней «на всякий случай» без роста диска.
- Хранить единственную копию снимков на том же SSD, что HOT.
- Включать `wazuh-archives-*` без отдельного расчёта диска (это не замена snapshot-архиву алертов).

---

## 5. Расчёт диска HOT и ARCHIVE

### 5.1. Формулы

```
HOT_primary_90d = N_ws×1.5 + N_srv×3.7 + N_net×7.4   (GB)
HOT_cluster     = HOT_primary_90d × (1 + replica) × 1.25   # replica=1 → ×2×1.25
HOT_single      = HOT_primary_90d × 1.25                   # compact без replica shards

ARCHIVE_year    ≈ HOT_primary_90d × (365/90) × 0.85       # ~0.85 из‑за сжатия снимков
ARCHIVE_years   = ARCHIVE_year × ARCHIVE_YEARS
```

`0.85` — консервативно (снимки часто жмут сильнее; не занижаем диск ARCHIVE).

### 5.2. Сценарий 100 агентов (70/25/5)

| Величина | Значение |
|---|---|
| HOT primary 90d | **235 GB** |
| HOT PVC compact (single) | **300 Gi** |
| HOT HA (replica=1 + запас) | **~600 Gi** → 3× **200 Gi** |
| ARCHIVE 1 год | 235 × 4.06 × 0.85 ≈ **810 GB** → том **1 Ti** |
| ARCHIVE 3 года | ≈ **2.4 Ti** |

### 5.3. Сценарий 1000 агентов

| Величина | Значение |
|---|---|
| HOT primary 90d | **2.3 Ti** |
| HOT HA | **~6 Ti** → 3× **2 Ti** |
| ARCHIVE 1 год | ≈ **8 Ti** (том **8–10 Ti**, лучше HDD/объектное) |
| ARCHIVE 3 года | ≈ **24 Ti** |

---

## 6. Официальный baseline CPU/RAM + K8s

| Компонент | Official recommended | В K8s добавляем |
|---|---|---|
| Indexer | 8 CPU / 16 GB | + kubelet/CNI; page cache в cgroup пода; +CP если совмещён |
| Server | 8 CPU / 4 GB | workers выше по RAM (очереди analysisd) |
| Dashboard | 4 CPU / 8 GB | + Ingress/MetalLB на ноде |

Сигналы overload manager: `events_dropped` (analysisd), `discarded_count` (remoted) → должны быть **0**.

---

## 7. Сценарий A: до 100 агентов (compact + ARCHIVE) — рекомендуемый

### 7.1. Вердикт

**4 Wazuh-пода + ARCHIVE / 4 ВМ / ~24 vCPU / ~64–72 Gi RAM / ~400 Gi HOT SSD + ~1 Ti ARCHIVE**

Схема **рабочая** для production без HA indexer. История >90 дней — **только из ARCHIVE**.

### 7.2. Поды

| Компонент | N | CPU req→lim | RAM req→lim | PVC | Почему |
|---|---:|---|---|---|---|
| master | 1 | 1→2 | 2→4 Gi | 50 Gi | authd/API; лёгкий |
| worker | 1 | 2→4 | 4→8 Gi | 50 Gi | весь `:1514` |
| indexer | 1 | 2→4 | 12→**24 Gi** | **300 Gi SSD** | heap **8g**; остаток Lucene |
| dashboard | 1 | 0.5→2 | 1→4 Gi | — | UI |
| archive | — | вне K8s или Deploy MinIO | см. ВМ | **1 Ti** | снимки |

Не ставить master+worker оба с lim 8 Gi на ВМ 16 Gi.

### 7.3. ВМ

| # | Роль | vCPU | RAM | OS | Data | Поды / сервисы |
|---|---|---:|---:|---:|---:|---|
| 1 | Indexer (+ K8s CP) | 8 | 32 Gi | 80 Gi | **300 Gi SSD** | indexer-0; `path.repo` → mount ARCHIVE |
| 2 | Manager | 8 | **24 Gi** | 80 Gi | 100 Gi SSD | master + worker |
| 3 | Dashboard | 4 | 8 Gi | 60 Gi | — | dashboard, Ingress |
| 4 | **Archive** | 4 | 8 Gi | 60 Gi | **1 Ti** (SSD или HDD) | NFS server **или** MinIO |

Почему Archive отдельно: снимки не должны жить на том же диске, что HOT; NFS — путь из [официальной миграции индексов Wazuh](https://documentation.wazuh.com/current/user-manual/wazuh-indexer/migrating-wazuh-indices.html).

### 7.4. Суммарно (100 compact)

| Метрика | Значение |
|---|---|
| ВМ | **4** |
| vCPU | ~24 |
| RAM | ~72 Gi |
| HOT data SSD | ~400 Gi |
| ARCHIVE | **1 Ti** (1 год) |
| Рабочесть | **Рабочая** |

### 7.5. HA-вариант 100 (если нужен SLA)

| | Значение |
|---|---|
| Поды | 1 master + 2 workers + 3 indexer + 2 dashboard |
| Indexer ВМ | 3× **8 vCPU** / 16–24 Gi / data **200 Gi** |
| Archive | 1 ВМ **1–2 Ti** (лучше NFS за всеми indexer) |
| Итого | ~7 ВМ, ~48 vCPU, ~100 Gi RAM, ~750 Gi HOT + 1–2 Ti ARCHIVE |

---

## 8. Сценарий B: до 1000 агентов (HA + ARCHIVE) — рекомендуемый

### 8.1. Вердикт

**9 Wazuh-подов / 8 compute ВМ + 1–2 ARCHIVE / ~120+ vCPU / ~304+ Gi / ~6.4 Ti HOT + ~8–10 Ti ARCHIVE**

Схема **рабочая с запасом**. LB на `:1514` **обязателен**.

### 8.2. Поды

| Компонент | N | CPU lim | RAM lim | PVC |
|---|---:|---|---|---|
| master | 1 | 8 | 16 Gi | 100 Gi |
| worker | **3** | 8 | 16 Gi | 100 Gi each |
| indexer | **3** | 8–16 | **40–48 Gi** (heap 16g) | **2 Ti** each |
| dashboard | **2** | 2 | 4 Gi | — |

### 8.3. ВМ

| # | Роль | vCPU | RAM | OS | Data |
|---|---|---:|---:|---:|---:|
| 1–3 | Indexer | 16 | 64 Gi | 120 Gi | **2 Ti SSD** (+ mount NFS repo) |
| 4 | Master | 16 | 32 Gi | 100 Gi | 100 Gi |
| 5–7 | Worker | 16 | 32 Gi | 100 Gi | 100 Gi |
| 8 | Dashboard | 8 | 16 Gi | 100 Gi | — |
| 9 | **Archive NFS/MinIO** | 8 | 16 Gi | 100 Gi | **8–10 Ti** (HDD OK для холодного) |
| 9b (opt) | Archive replica | 8 | 16 Gi | 100 Gi | зеркало/replication MinIO |

Master/worker 16/32 — conservative (official server 8/4); резать только под метриками дропов.

### 8.4. Суммарно

| Метрика | Значение |
|---|---|
| Compute ВМ | 8 |
| Archive ВМ | 1–2 |
| HOT SSD | ~6.4 Ti |
| ARCHIVE | **8–10 Ti** (1 год) |
| Рабочесть | **Рабочая HA** |

---

## 9. Сеть

| Порт | Назначение |
|---:|---|
| 1514 | LB → workers (events) |
| 1515 | LB → master (enrollment) |
| 1516 | cluster internal |
| 55000 | API internal |
| 9200/9300 | indexer |
| 443 | UI |
| 2049 | NFS ARCHIVE ← indexer nodes |
| 9000 | MinIO API (если S3) |

Firewall: агентские сети только на VIP 1514/1515/443; ARCHIVE — только с indexer CIDR.

---

## 10. Когда масштабировать

| Сигнал | Действие |
|---|---|
| `events_dropped` / `discarded_count` > 0 | +worker |
| HOT disk >70% | расширить PVC **или** проверить, что ISM delete реально работает |
| Snapshot fail | чинить ARCHIVE/NFS до заполнения HOT |
| ARCHIVE >80% | расширить том или снизить `ARCHIVE_YEARS` / чистить старые снимки |
| Search latency / heap >75% | RAM/CPU indexer; heap ≤32g |
| Агенты ≫ текущего сценария | пересмотр по таблице сравнения |

---

## 11. Сравнение

| | 100 compact+archive | 100 HA+archive | 1000 HA+archive |
|---|---|---|---|
| Wazuh-поды | 4 | 8 | 9 |
| Compute ВМ | 3 | ~6 | 8 |
| Archive ВМ | **1** | **1** | **1–2** |
| HOT | ~400 Gi | ~750 Gi | ~6.4 Ti |
| ARCHIVE (1г) | **~1 Ti** | **~1–2 Ti** | **~8–10 Ti** |
| После 90 дней | снимок → delete HOT | то же | то же |
| LB :1514 | желателен | да | **обязателен** |
| Оценка | **рабочая** | **рабочая** | **рабочая с запасом** |

---

## 12. Чеклист принятия архитектуры

- [ ] Зафиксирован контракт: HOT 90d + ARCHIVE ≥1 год (или явное «удалять навсегда» — тогда Archive ВМ не нужна, но это другое решение)
- [ ] Archive не на том же диске, что indexer PVC
- [ ] Ежедневный snapshot + мониторинг успеха
- [ ] ISM delete не опережает успешный снимок
- [ ] Процедура Restore документирована и проверена на стенде
- [ ] `wazuh-archives-*` выключен, если не считали отдельный диск
- [ ] SSD только на HOT; ARCHIVE допускается HDD/объектное

Установка и настройка пошагово: [wazuh-install.md](wazuh-install.md).
