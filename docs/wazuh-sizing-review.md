# Перепроверка sizing Wazuh (K8s): почему столько ресурсов и насколько схема рабочая

Опора: официальные Hardware recommendations Wazuh ([indexer](https://documentation.wazuh.com/current/installation-guide/wazuh-indexer/index.html), [server](https://documentation.wazuh.com/current/installation-guide/wazuh-server/index.html), [dashboard](https://documentation.wazuh.com/current/installation-guide/wazuh-dashboard/index.html)) + overhead Kubernetes + правило heap indexer = ½ RAM пода.

Шкала оценки схемы:

| Оценка | Смысл |
|---|---|
| **Рабочая с запасом** | Можно брать в production as-is |
| **Рабочая, но тугая** | Заведётся; нужны requests < limits или чуть поднять ВМ |
| **Запас избыточен** | Не ошибка, можно урезать без риска для 100/1000 агентов при типичном APS |
| **Слабое место** | Лучше поправить до внедрения |

---

## 1. Пересчёт диска indexer (официальная таблица)

Допущение парка: 70% WS / 25% servers / 5% network, retention **90 дней**.

Официально (GB / агент / 90 дней в **indexer**):

| Тип | APS | GB/90d |
|---|---:|---:|
| Workstation | 0.1 | 1.5 |
| Server | 0.25 | 3.7 |
| Network | 0.5 | 7.4 |

### 100 агентов

| Тип | Кол-во | Формула | GB |
|---|---:|---|---:|
| WS | 70 | 70 × 1.5 | 105.0 |
| Server | 25 | 25 × 3.7 | 92.5 |
| Network | 5 | 5 × 7.4 | 37.0 |
| **Primary** | 100 | | **234.5 ≈ 235** |

| Режим | Расчёт | Итог |
|---|---|---|
| Single-indexer (compact, без replica shards) | 235 × 1.25 запас | **≈ 294 → PVC 300 Gi** |
| Cluster replica=1 | 235 × 2 ≈ 470; ×1.25 ≈ 588 | **≈ 600 Gi на кластер** |
| HA 3 ноды | 600 / 3 | **≈ 200 Gi на ноду → PVC 200 Gi** |

**Вердикт по диску 100:** цифры в architecture-доке **верны**. Compact 300 Gi — корректно именно потому, что нет второго набора primary/replica shards.

### 1000 агентов

| Тип | Кол-во | GB |
|---|---:|---:|
| WS | 700 | 1050 |
| Server | 250 | 925 |
| Network | 50 | 370 |
| **Primary** | | **2345 ≈ 2.3 Ti** |

| Режим | Расчёт | Итог |
|---|---|---|
| replica=1 | 2.3 × 2 ≈ 4.6 Ti | |
| +25% запас | 4.6 × 1.25 ≈ 5.75 | **≈ 5.8–6 Ti** |
| 3 indexer | 6 / 3 | **≈ 2 Ti PVC каждый** |

**Вердикт по диску 1000:** цифры **верны**.

> Диск **manager** по доке Wazuh другой (на сервере ~0.04 / 0.1 / 0.2 GB/агент/90d). Для 100 агентов это ~6–7 GB алертов на server-side, не 100 GB. PVC 50 Gi на master/worker — это **не под алерты**, а под очереди, логи, agent-groups, upgrades, var/ossec. Запас большой, но оправдан как «не упираться в диск менеджера».

---

## 2. Официальный baseline «железа» (без K8s)

| Компонент | Minimum | Recommended |
|---|---|---|
| Indexer (на ноду) | 2 CPU / 4 GB | **8 CPU / 16 GB** |
| Server / manager (на ноду) | 2 CPU / 2 GB | **8 CPU / 4 GB** |
| Dashboard | 2 CPU / 4 GB | **4 CPU / 8 GB** |

Scaling-сигналы (официально): `events_dropped` (analysisd), `discarded_count` (remoted) → должны быть **0**; иначе +worker.

В Kubernetes сверху нужны: kubelet, containerd, CNI, иногда control-plane / Ingress / MetalLB ≈ **1.5–4 Gi RAM и 0.5–2 vCPU на ноду**, плюс для indexer — осмысленный запас RAM под Lucene/page cache.

---

## 3. Сценарий A — 100 агентов (compact): разбор по ВМ

### 3.1 ВМ `Indexer` — 8 vCPU / 32 Gi / data 300 Gi SSD

| Слой | Выделение | Зачем |
|---|---|---|
| Pod indexer limits | 4 CPU / **16 Gi**, heap **-Xms8g -Xmx8g** | Совпадает с official **Recommended 8 CPU / 16 GB** по RAM; CPU пода 4 — ниже recommended 8, но для ~235 GB primary и ~15–20 APS суммарно (100×~0.15) достаточно |
| Остаток ВМ RAM (~16 Gi) | OS + kubelet + containerd + CNI + **control-plane** (в compact эта нода — ещё и master K8s) | etcd/apiserver легко берут 2–4 Gi; без запаса control-plane будет давить indexer |
| Data 300 Gi SSD | primary 235 + 25% | Согласовано с пересчётом; SSD обязателен (IOPS merge/refresh/search) |
| OS disk 80 Gi | образы, logs, containerd snapshotter | Норма для worker+CP |

**Почему не 16 Gi на всю ВМ:** на bare-metal «16 GB = нода indexer». В compact на этой же ВМ крутится Kubernetes API — **32 Gi оправданы**.

**Нюанс K8s:** page cache частично учитывается в cgroup пода. Поэтому «лишние» 16 Gi на ВМ *не полностью* работают как file cache indexer, если pod limit = 16 Gi. Практичнее:

- оставить ВМ **32 Gi**;
- поднять pod limit до **20–24 Gi**, heap оставить **8g** (или 10g), чтобы Lucene жил внутри cgroup.

**Оценка:** **рабочая с запасом** (после уточнения pod memory 20–24 Gi — ещё лучше). CPU 8 на ВМ при pod lim 4 — запас под kube-system и краткие пики.

---

### 3.2 ВМ `Manager` — 8 vCPU / 16 Gi / data 100 Gi

| Слой | Выделение | Зачем |
|---|---|---|
| Pod master | lim 4 CPU / 8 Gi, PVC 50 Gi | authd/API/cluster; нагрузка от 100 агентов на enrollment редкая; 8 Gi RAM **выше** official recommended 4 GB — запас под API + K8s |
| Pod worker | lim 4 CPU / 8 Gi, PVC 50 Gi | весь event-path `:1514`; для 100 агентов 1 worker — норма; CPU близок к recommended 8, RAM выше official 4 GB |
| Сумма limits | **8 CPU / 16 Gi** | Равно размеру ВМ → **нет воздуха** под OS/kubelet (~2–3 Gi) |
| Data 100 Gi | 2×50 Gi PVC | Для manager-side алертов хватило бы ~10 Gi; 50 Gi — запас под queues/`/var/ossec` |

**Слабое место:** если оба пода одновременно упрутся в limits, kubelet/OS начнут испытывать memory pressure (node NotReady / eviction).

**Как сделать схему реально рабочей без смены топологии:**

| Параметр | Было | Рекомендуемая правка |
|---|---|---|
| master requests/limits | 2→4 / 4→8 Gi | **1→2 CPU / 2→4 Gi** (enrollment+API) |
| worker requests/limits | 2→4 / 4→8 Gi | **2→4 CPU / 4→8 Gi** |
| ВМ RAM | 16 Gi | **оставить 16 Gi** *или* поднять до **24 Gi**, если хотите оба high-limit |

При правых requests scheduler видит суммарно ~6 Gi + система, а не 16 Gi «впритык».

**Оценка сейчас:** **рабочая, но тугая** на RAM. После правки requests/limits master — **рабочая с запасом**. Для 100 агентов 1 worker — **рабочая схема** (официальный scaling — по `events_dropped`/`discarded_count`, не по «магическому» числу агентов).

---

### 3.3 ВМ `Dashboard` — 4 vCPU / 8 Gi / OS 60 Gi

| Слой | Выделение | Зачем |
|---|---|---|
| Official dashboard | Recommended **4 CPU / 8 GB** | ВМ совпадает 1:1 |
| Pod lim | 1 CPU / 2 Gi | Ниже recommended; остаток ВМ — Ingress, MetalLB speaker, CNI, kubelet |
| Data | нет | Stateless Deployment |

**Оценка:** **рабочая с запасом** для UI. Имеет смысл поднять pod до **2 CPU / 4 Gi**, если в UI много одновременных пользователей/тяжёлых Discover-запросов.

---

### 3.4 Итог compact 100: «насколько рабочая»

| Вопрос | Ответ |
|---|---|
| Заведётся ли на 100 агентах смешанного парка? | **Да** |
| Соответствует ли диск официальной формуле? | **Да** (300 Gi single-node) |
| Где риск? | Manager-ВМ: сумма pod limits = RAM ВМ; single indexer = нет HA данных |
| Нужен ли LB :1514? | Желателен (единый endpoint), для 1 worker не критичен для балансировки |
| Когда схема перестанет быть рабочей? | Рост APS (syscheck/sca/vuln в «шумном» режиме), PVC >70%, ненулевые `events_dropped`/`discarded_count` |

**Итоговая оценка compact 100: рабочая production-схема для одного площадочного контура без жёсткого HA.** Не lab-минимум.

---

## 4. Сценарий A — HA 100 агентов: перепроверка

Было в architecture: 3× indexer ВМ **4 vCPU / 16 Gi / data 200 Gi**.

| Параметр | Оценка |
|---|---|
| Data 3×200 Gi | **Верно** (~600 Gi кластер) |
| RAM 16 Gi / нода | Совпадает с official Recommended **16 GB** |
| CPU 4 | **Слабое место** vs official Recommended **8 CPU**; для 100 агентов нагрузка на поиск невелика, но лучше **8 vCPU** |
| 2 workers | Избыточно по агентам, полезно для HA при rolling restart |
| ~6 ВМ / ~28 vCPU / ~80 Gi | Рабочая, CPU indexer лучше поднять |

**Оценка HA 100:** **рабочая**, после правки indexer-ВМ до **8 vCPU / 16–24 Gi** — **рабочая с запасом**.

---

## 5. Сценарий B — 1000 агентов (HA): разбор по ВМ

Оценка APS порядка: 700×0.1 + 250×0.25 + 50×0.5 ≈ **70 + 62.5 + 25 = 157.5 APS** среднего уровня алертов (не сырой EPS агентов). Реальный EPS на remoted выше APS; поэтому workers масштабируют по `discarded_count`/`events_dropped`.

### 5.1 Indexer ×3 — каждая 16 vCPU / 64 Gi / 2 Ti SSD

| Слой | Зачем столько |
|---|---|
| PVC 2 Ti | 6 Ti кластер / 3 — подтверждено пересчётом |
| Pod 8–16 CPU / 32 Gi, heap 16g | Выше official 8/16: на ноду приходится ~2 Ti данных и поисковая нагрузка UI + ingest Filebeat с 3 workers |
| ВМ 64 Gi при pod 32 Gi | Запас под OS + **file cache**; на больших томах OpenSearch сильно выигрывает от RAM. Как и в §3.1, лучше pod limit **40–48 Gi**, heap **16g** (не поднимать heap >32g) |
| 16 vCPU | Запас под merge/refresh/search; official 8 — минимум «комфорта», не потолок для 2 Ti |

**Оценка:** **рабочая с запасом**. Можно урезать ВМ до **16 vCPU / 48 Gi** при pod 32–40 Gi, если экономия критична — всё ещё ок.

### 5.2 Manager-master — 16 vCPU / 32 Gi / data 100 Gi

| Слой | Зачем |
|---|---|
| Official server | 8 CPU / 4 GB recommended |
| Pod 8/16 Gi на ВМ 16/32 | **Запас избыточен** относительно official, но master в K8s + API + authd при массовом enrollment 1000 агентов получает пики |
| Не принимает :1514 | Верно по архитектуре Wazuh cluster |

**Оценка:** **запас избыточен**, но **рабочая**. Рациональный floor: ВМ **8 vCPU / 16 Gi**, pod **4 CPU / 8 Gi**. Текущие 16/32 — « Tolсто» для спокойствия, не ошибка расчёта диска/APS.

### 5.3 Manager-worker ×3 — каждая 16 vCPU / 32 Gi / data 100 Gi

| Слой | Зачем |
|---|---|
| ~333 агента на worker | Правило «агенты/worker» условное; официально смотрят дропы |
| Pod 8 CPU / 16 Gi | Выше official 8/4: analysisd+remoted+Filebeat под 1000 агентов — главное узкое место CPU |
| 3 workers + LB :1514 | **Обязательная** рабочая схема: без LB sticky/перекос на одного worker |
| PVC 100 Gi | Снова запас; manager-side disk для ~333 агентов ≪ 100 Gi |

**Оценка:** **рабочая с запасом**. Floor: ВМ **8–12 vCPU / 24 Gi**, pod **4–8 CPU / 8–16 Gi**. Текущий план — conservative production.

### 5.4 Dashboard — 8 vCPU / 16 Gi, 2 пода

| Слой | Зачем |
|---|---|
| Official | 4/8 на один dashboard |
| 2 replicas на одной ВМ | HA процесса, но **не** HA ноды (SPOF ВМ) — это уже отмечено в architecture |
| 8/16 | Как раз под 2×(2–4 Gi) + Ingress |

**Оценка:** **рабочая**; для настоящего HA UI — 2 ВМ.

### 5.5 Итог 1000

| Вопрос | Ответ |
|---|---|
| Рабочая ли схема? | **Да, production HA** |
| Где перепрод? | Manager master/worker RAM/CPU выше official «recommended» |
| Где обязательно не резать? | 3 indexer, 2 Ti, LB :1514, anti-affinity indexer |
| Главный риск при урезании | Не диск, а CPU workers при высоком EPS (FIM/SCA/syslog) |

---

## 6. Сводка: было → оценка → правка (если нужна)

### 100 агентов compact

| ВМ | Было | Оценка | Рекомендуемая правка |
|---|---|---|---|
| Indexer 8/32 / 300 Gi | Верно + запас на CP | **Рабочая с запасом** | Pod RAM **20–24 Gi**, heap 8g |
| Manager 8/16 / 100 Gi | Limits 8+8 Gi = ВМ | **Тугая** | Master lim **2 CPU / 4 Gi**; или ВМ **24 Gi** |
| Dashboard 4/8 | Совпадает с official | **Рабочая с запасом** | Pod **2/4 Gi** при активном UI |
| **Схема в целом** | | **Рабочая** для production без HA | |

### 100 агентов HA

| Элемент | Оценка | Правка |
|---|---|---|
| 3× indexer data 200 Gi | Верно | — |
| Indexer 4 vCPU | **Слабое место** | **8 vCPU / 16–24 Gi** |
| 2 workers | Рабочая | — |

### 1000 агентов HA

| ВМ | Оценка | Правка |
|---|---|---|
| Indexer 16/64 / 2 Ti | **Рабочая с запасом** | Pod 40–48 Gi optional |
| Master 16/32 | **Запас избыточен** | Можно 8/16 |
| Worker 16/32 ×3 | **Рабочая с запасом** | Не резать ниже ~8/24 без мониторинга дропов |
| Dashboard 8/16 (2 pod) | **Рабочая**, SPOF ноды | 2 ВМ если нужен HA UI |
| **Схема в целом** | **Рабочая HA production** | |

---

## 7. Почему нельзя ориентироваться только на «число агентов»

Официальная логика:

1. Диск indexer = **Σ (агенты_типа × GB/90d)** × replica × запас.
2. CPU/RAM manager = пока `events_dropped` и `discarded_count` == 0.
3. APS в таблице — **алерты**, не сырой eps syslog/FIM; шумный парк (много servers + windows syscheck) потребует workers раньше, чем «1000 агентов».

Поэтому план «1 worker на 100» и «3 workers на 1000» — **разумный baseline**, а не гарантия. Мониторинг дропов обязателен с первого дня.

---

## 8. Короткий вердикт

| Сценарий | Насколько рабочая схема | Главный вывод по ресурсам |
|---|---|---|
| **100 compact** | **Рабочая** | Диск и indexer обоснованы; **подкрутить manager** (limits/VM RAM); 32 Gi indexer ОКны из‑за control-plane |
| **100 HA** | **Рабочая** | Диск ок; **поднять CPU indexer-ВМ с 4 до 8** |
| **1000 HA** | **Рабочая с запасом** | Диск/3×2 Ti верны; managers намеренно «толще» official — допустимо; резать только под метриками |

Итого: исходные цифры **не взяты с потолка** — диск совпадает с официальной таблицей Wazuh, CPU/RAM ВМ = official recommended + Kubernetes/HA-запас. Единственные места, где схема была бы хрупкой без правки: **manager 16 Gi при двух limits по 8 Gi** и **HA indexer на 4 vCPU**.
