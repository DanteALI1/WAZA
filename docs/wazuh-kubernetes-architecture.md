# Развёртывание Wazuh в Kubernetes

Production-oriented план для двух сценариев: **до 100 агентов** и **до 1000 агентов**.

## Контекст и допущения

- Смешанный парк: ~70% workstations, ~25% servers, ~5% network devices
- Retention алертов в indexer: **90 дней**
- Sizing от EPS/APS и retention, не только от числа агентов
- Масштабирование manager — горизонтально (workers)
- Сигналы перегрузки: `events_dropped` (analysisd) и `discarded_count` (remoted)
- Оценка диска indexer (GB/агент/90 дней): workstation **1.5**, server **3.7**, network **7.4**
- При `replica=1` объём примерно ×2 + ~25% запас
- Диски indexer только **SSD** с нормальным IOPS
- Heap indexer = половина RAM пода (`-Xms=-Xmx`)
- Не использовать дефолтные мелкие лимиты wazuh-kubernetes EKS overlay (типа 1 CPU / 2 Gi / 10 Gi на indexer) — это lab-шаблон

## Архитектура компонентов

| Компонент | Kind | Кол-во | Порты / роль |
|---|---|---|---|
| `wazuh-manager-master` | StatefulSet | всегда **1** | authd `:1515`, API `:55000`, cluster `:1516` |
| `wazuh-manager-worker` | StatefulSet | **N** | события агентов `:1514`, анализ, Filebeat → indexer `:9200` |
| `wazuh-indexer` | StatefulSet | **M** | хранение/поиск, cluster `:9300` |
| `wazuh-dashboard` | Deployment | **K** | UI `:443` → indexer + manager API |
| Внешний LB / Ingress | — | — | `:1514`, `:1515`, `:443` |

**Anti-affinity:** не сажать два indexer на одну ВМ; manager-поды по возможности разносить.

```
[Agents] --:1515--> LB --> master (authd)
[Agents] --:1514--> LB --> workers (remoted → analysisd → Filebeat)
                                      |
                                      v :9200
                              indexer cluster (:9300)
                                      ^
[Users]  --:443--> Ingress --> dashboard --> API :55000 (master)
```

- Master **не** принимает массовый event-трафик; масштабирование — **workers**.

---

## Сценарий A: до 100 агентов

### 1) Вердикт (компактный, рекомендуемый)

**4 пода / 3 ВМ / ~20 vCPU / ~56–64 Gi RAM / ~400 Gi data SSD** — схема **рабочая** для production без HA.

Оценка данных: ~235 GB primary → ~470 GB (replica=1) → ~600 GB с запасом; для single-indexer достаточно **~300 Gi PVC**.

### 2) Топология подов

| Компонент | Кол-во | CPU req→lim | RAM req→lim | PVC | Почему |
|---|---:|---|---|---|---|
| `wazuh-manager-master` | 1 | 1→2 | 2→4 Gi | 50 Gi | authd `:1515`, API `:55000`, cluster `:1516`; enrollment лёгкий; не забирает всю RAM ВМ |
| `wazuh-manager-worker` | 1 | 2→4 | 4→8 Gi | 50 Gi | события агентов `:1514`, analysisd, Filebeat→indexer |
| `wazuh-indexer` | 1 | 2→4 | 12→**24 Gi** | **300 Gi SSD** | хранение/поиск; heap `-Xms8g -Xmx8g`; остаток cgroup — Lucene/page cache |
| `wazuh-dashboard` | 1 | 0.5→2 | 1→4 Gi | — | UI `:443`; official recommended dashboard = 4 CPU / 8 GB на ноду |

**Итого подов: 4.** Anti-affinity: indexer и managers на разных ВМ; на 3 ВМ worker и master соседствуют на одной manager-ноде — приемлемо для compact.

> Перепроверка и «почему столько»: [wazuh-sizing-review.md](wazuh-sizing-review.md). Диск 300 Gi = 235 GB primary ×1.25 (single-node без replica).

### 3) Раскладка ВМ

| # | Роль ВМ | vCPU | RAM | OS disk | Data disk | Поды |
|---|---|---:|---:|---:|---:|---|
| 1 | Indexer (+ K8s CP) | 8 | 32 Gi | 80 Gi | **300 Gi SSD** | 1× indexer |
| 2 | Manager | 8 | **16–24 Gi** | 80 Gi | **100 Gi SSD** (2×50 Gi PVC) | 1× master + 1× worker |
| 3 | Dashboard | 4 | 8 Gi | 60 Gi | — | 1× dashboard |

Почему indexer-ВМ 32 Gi: official indexer recommended = 16 GB **плюс** control-plane/kubelet на той же ноде в compact. Pod лучше 20–24 Gi (не 16), чтобы page cache жил в cgroup. Manager 16 Gi рабочий **только если** master limits ≤4 Gi; иначе взять **24 Gi**.

### 4) Суммарные ресурсы

| Метрика | Значение |
|---|---|
| ВМ | 3 |
| vCPU | 20 |
| RAM | **56–64 Gi** (16 или 24 Gi на manager-ВМ) |
| OS disks | ~220 Gi |
| Data SSD | ~400 Gi |
| Оценка схемы | **Рабочая** (без HA данных); см. [sizing-review](wazuh-sizing-review.md) |

### 5) Сеть / порты / LB

| Порт | Куда | Назначение |
|---:|---|---|
| **1514** | LB → worker(s) | события агентов (TCP) |
| **1515** | LB → master | enrollment (authd) |
| **1516** | только internal | cluster sync master↔workers |
| **55000** | internal / API | Wazuh API (dashboard) |
| **9200** | internal | indexer HTTP |
| **9300** | internal | indexer transport |
| **443** | Ingress/LB → dashboard | UI |

Для 100 агентов достаточно 1 worker; LB на `:1514` всё равно желателен (единая точка для агентов, удобный upgrade).

### 6) Когда масштабировать

| Сигнал | Действие |
|---|---|
| `events_dropped` (analysisd) растёт / queue analysisd заполнена | +1 worker |
| `discarded_count` (remoted) растёт | +1 worker (или больше CPU/RAM worker) |
| Indexer disk >70–75% / heap pressure / slow search | увеличить PVC → 500–600 Gi **или** перейти на 3 indexer (HA) |
| Dashboard latency / недоступность UI | +1 dashboard replica |
| Агенты >~100 или стабильный рост EPS | пересмотр по сценарию B |

### 7) Компактный vs HA

**Компактный (предпочитаемый):** см. выше — 4 пода / 3 ВМ.

**HA (если нужен):**

| | Значение |
|---|---|
| Поды | 1 master + **2** workers + **3** indexer + **2** dashboard = **8** |
| Indexer ВМ | 3× (**8** vCPU / 16–24 Gi / data **200 Gi** SSD), 1 pod/ВМ; heap 8g — **не 4 vCPU** (official recommended = 8 CPU) |
| Manager | отдельная ВМ или 2 ВМ под master+workers |
| Dashboard | 2 replica (на одной или двух ВМ) |
| **Итого ~** | **6 ВМ, ~40 vCPU, ~80–100 Gi RAM, ~750 Gi data SSD** |

Replica=1 на 3 нодах → данные ~600 Gi кластера распределяются; 3×200 Gi с запасом.

---

## Сценарий B: до 1000 агентов

### 1) Вердикт (HA, рекомендуемый)

**9 подов / 8 ВМ / ~120 vCPU / ~304 Gi RAM / ~6.4 Ti data SSD**

Оценка данных: ~2.3 TB primary → ~4.6 TB (replica) → ~5.8–6 TB с запасом → **~2 Ti PVC × 3 indexer**.

### 2) Топология подов

| Компонент | Кол-во | CPU req→lim | RAM req→lim | PVC | Почему |
|---|---:|---|---|---|---|
| `wazuh-manager-master` | 1 | 4→8 | 8→16 Gi | 100 Gi | authd, API, cluster; без приёма массовых events |
| `wazuh-manager-worker` | **3** | 4→8 | 8→16 Gi | 100 Gi каждый | горизонтальное масштабирование анализа; ~300–350 агентов/worker с запасом |
| `wazuh-indexer` | **3** | 4→**8–16** | 24→**40–48 Gi** (лимит; heap **16g**) | **2 Ti SSD** каждый | shard + replica; heap 16g, остаток cgroup — Lucene; ВМ 64 Gi |
| `wazuh-dashboard` | **2** | 1→2 | 2→4 Gi | — | HA UI за Ingress |

**Итого подов: 9.** Hard anti-affinity для indexer (1 pod / 1 ВМ). Soft/hard anti-affinity для manager-подов — каждый на своей ВМ.

### 3) Раскладка ВМ (чистые failure domains)

| # | Роль ВМ | vCPU | RAM | OS disk | Data disk | Поды |
|---|---|---:|---:|---:|---:|---|
| 1–3 | Indexer ×3 | 16 | 64 Gi | 120 Gi | **2 Ti SSD** | 1× indexer на ВМ |
| 4 | Manager-master | 16 | 32 Gi | 100 Gi | 100 Gi | 1× master |
| 5–7 | Manager-worker ×3 | 16 | 32 Gi | 100 Gi | 100 Gi | 1× worker на ВМ |
| 8 | Dashboard | 8 | 16 Gi | 100 Gi | — | 2× dashboard |

Почему 64 Gi на indexer-ВМ: pod лучше 40–48 Gi (heap 16g + Lucene в cgroup) + OS/kubelet; file cache на 2 Ti SSD критичен для латентности поиска. Official recommended 8 CPU/16 GB — пол для малой ноды, не потолок для 2 Ti.

### 4) Суммарные ресурсы

| Метрика | Значение |
|---|---|
| ВМ | 8 |
| vCPU | 120 |
| RAM | 304 Gi |
| OS disks | ~860 Gi |
| Data SSD | **~6.4 Ti** (3×2 Ti + 4×100 Gi managers) |

### 5) Сеть / порты / LB

| Порт | Куда | Назначение |
|---:|---|---|
| **1514** | **обязательный LB** → workers (round-robin / least-conn) | events; без LB агенты «прилипают» к одному worker |
| **1515** | LB → master | enrollment |
| **1516** | ClusterIP / internal | cluster |
| **55000** | internal | API |
| **9200 / 9300** | headless + ClusterIP | indexer |
| **443** | Ingress → dashboard×2 | UI |

Рекомендация: отдельный L4 LB (NLB/HAProxy) для 1514/1515; Ingress/L7 только для dashboard.

### 6) Когда масштабировать

| Сигнал | Действие |
|---|---|
| `events_dropped` / высокая load analysisd на workers | +1 worker (+ ВМ 16/32/data 100) |
| `discarded_count` (remoted) | +1 worker или увеличить lim CPU/RAM worker |
| Indexer disk >70% / cluster relocating постоянно | расширить PVC (→2.5–3 Ti) **или** +2 indexer (кворум 5) |
| Heap >75%, GC, search latency | поднять RAM пода до 48–64 Gi (heap ≤32g — выше неэффективно для OpenSearch JVM) |
| EPS/APS выше ожидаемого при том же числе агентов | сначала workers, потом indexer CPU/IOPS |
| Dashboard SPOF на одной ВМ | вынести 2-й dashboard на 9-ю ВМ |

### 7) Компактный vs HA

**HA (предпочитаемый):** см. выше — 9 подов / 8 ВМ.

**Компактный (только если нет SLA на downtime / staging):**

| | Значение |
|---|---|
| Поды | 1 master + 2 workers + 1–2 indexer + 1 dashboard |
| Risk | single indexer = нет replica durability; 2 workers на грани по `discarded_count` |
| Пример | 1 indexer PVC ~5–6 Ti (нежелательно: recover/backup гигантский) **или** 2 indexer без кворума |
| Вердикт | для production 1000 агентов **не рекомендовать**; использовать HA |

---

## Сводное сравнение

| | **100 агентов (compact)** | **100 агентов (HA)** | **1000 агентов (HA)** |
|---|---|---|---|
| Поды | 4 (1+1+1+1) | 8 (1+2+3+2) | **9 (1+3+3+2)** |
| ВМ | **3** | ~6 | **8** |
| vCPU | **~20** | ~40 | **~120** |
| RAM | **~56–64 Gi** | ~80–100 Gi | **~304 Gi** |
| Data SSD | **~400 Gi** | ~750 Gi | **~6.4 Ti** |
| Indexer PVC | 1×300 Gi | 3×200 Gi | 3×2 Ti |
| Workers | 1 | 2 | 3 |
| LB `:1514` | желателен | да | **обязателен** |
| Рабочесть схемы | **рабочая** (подкрутить manager limits) | **рабочая** (indexer ≥8 vCPU) | **рабочая с запасом** |
| Рекомендация | **compact** | при SLA | **HA** |

Подробный разбор «почему столько на каждую ВМ»: [wazuh-sizing-review.md](wazuh-sizing-review.md).

### Инварианты обоих сценариев

- Master не принимает массовый event-трафик; масштабирование — workers
- Overload: `events_dropped` (analysisd) + `discarded_count` (remoted)
- Indexer: только SSD, anti-affinity 1 pod/ВМ, heap = ½ RAM пода
- Не опираться на дефолтные EKS-overlay лимиты wazuh-kubernetes
