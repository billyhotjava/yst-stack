# yts-doris Service

This directory holds persistent assets for the split Doris deployment used by the stack:

- `fe/meta`、`fe/log` → `/opt/apache-doris/fe/doris-meta` 与 `/opt/apache-doris/fe/log`
- `be/storage`、`be/log` → `/opt/apache-doris/be/storage` 与 `/opt/apache-doris/be/log`
- `broker/log` → `/opt/apache-doris/broker/log`

The containers expose the standard Doris ports:

- FE Web UI: `https://${HOST_DORIS}`（Traefik ↔️ FE 8030）
- FE MySQL: `yts-doris-fe:${DORIS_MYSQL_PORT}`
- BE Web: `http://yts-doris-be:${DORIS_BE_WEB_PORT}`
- Broker: `yts-doris-broker:${DORIS_BROKER_PORT}`

If you need to customize Doris configuration, drop overriding files under the corresponding `fe/`、`be/`、`broker/` subdirectories and mount them via the compose files.
