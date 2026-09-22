# Bootstrap-скрипты ВМ (после установки ОС, до K8s/Wazuh)

Готовят хост: пакеты, swap off, sysctl, DATA-диск, пользователи/sudo, firewall (с вопросом), NFS.

**Не ставят** Kubernetes, containerd-kube, wazuh-kubernetes — это следующий этап в [docs/wazuh-install.md](../../docs/wazuh-install.md).

## Скрипты

| ВМ | Скрипт |
|---|---|
| `k8s-indexer` | `bootstrap-k8s-indexer.sh` |
| `k8s-manager` | `bootstrap-k8s-manager.sh` |
| `k8s-dashboard` | `bootstrap-k8s-dashboard.sh` |
| `wazuh-archive` | `bootstrap-wazuh-archive.sh` |

Общая библиотека: `lib/common.sh`.

## Запуск

Скопируйте каталог `scripts/bootstrap` на ВМ (scp/usb) и:

```bash
cd scripts/bootstrap
chmod +x bootstrap-*.sh
sudo ./bootstrap-k8s-indexer.sh
# или
sudo ./bootstrap-k8s-manager.sh
sudo ./bootstrap-k8s-dashboard.sh
sudo ./bootstrap-wazuh-archive.sh --nfs-cidr 10.10.10.0/24
```

### Полезные опции

| Опция | Смысл |
|---|---|
| `-y` / `--yes` | Авто-YES на вопросы (опасно для mkfs) |
| `--data-disk /dev/sdb` | Явно указать DATA-диск |
| `--hostname k8s-indexer` | Имя хоста |
| `--nfs-cidr 10.10.10.0/24` | Только archive |

## Что делает каждый этап

1. Определение ОС (РЕД ОС / Astra)  
2. Инвентаризация (CPU/RAM/диски/сеть) → в отчёт  
3. Hostname + опционально `/etc/hosts`  
4. Swap off  
5. Базовые пакеты + chrony + open-vm-tools  
6. Пользователи **разграничения доступа**:
   - группа `wazuh-admins` + пользователь `wazuhadmin` → полный sudo  
   - группа `wazuh-operators` + `wazuhops` → только диагностика (journalctl, systemctl status, df, …)  
   - `~/.ssh/authorized_keys` подготовлены  
7. sysctl/modules (на K8s-нодах)  
8. SELinux/MAC — вопрос перед Permissive  
9. DATA-диск — **вопрос перед mkfs**; mount `/data/wazuh` или `/mnt/snapshots`  
10. Firewall — **показывает правила и спрашивает** применять ли; пишет, что именно открыл  
11. Archive: NFS export; Indexer: опциональный mount NFS  

При ошибке команды: код возврата + хвост вывода в консоль и в DEBUG-лог.

## Логи

| Файл | Содержимое |
|---|---|
| `/var/log/wazuh-bootstrap/bootstrap-report-*.txt` | человекочитаемый отчёт этапов |
| `/var/log/wazuh-bootstrap/bootstrap-debug-*.log` | полный debug |

Права на каталог логов: `750`.

## Права на данные

- `/data/wazuh` → `root:wazuh-admins` mode `2770`  
- `/mnt/snapshots` на archive → по вопросу `1000:1000` (под контейнер indexer) или `root:wazuh-admins`  

## Важно

- Запускать **только после** установки ОС с разметкой EFI/boot/`/` без swap (см. архитектуру).  
- DATA-диск в установщике ОС лучше оставить пустым — скрипт разметит сам после подтверждения.  
- IP в `/etc/hosts` шаблонные `10.10.10.x` — согласитесь только если они ваши, либо правьте файл вручную.  
