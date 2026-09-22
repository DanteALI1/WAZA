# WAZA

Production-контур Wazuh в Kubernetes на **VMware ESXi 7**.

## Документы

1. [Архитектура](docs/wazuh-architecture.md) — ВМ и параметры ESXi 7, разметка разделов ОС, HOT 90 дней, отдельный сервер ARCHIVE, ежедневные снимки, Restore и просмотр в Dashboard, sizing 100/1000 агентов.
2. [Установка и настройка](docs/wazuh-install.md) — от создания ВМ в ESXi до агентов: РЕД ОС 8, Astra SE 1.7/1.8, K8s, Wazuh, NFS-архив, daily snapshot, ISM, процедура просмотра архива.

## Данные после 90 дней

Без ARCHIVE индексы **удаляются**. В этом проекте: ежедневный snapshot на отдельную ВМ NFS → ISM delete с HOT → при необходимости Restore → просмотр в Wazuh Dashboard.
