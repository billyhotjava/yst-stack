# YTS Big Data Stack (Traefik + Keycloak + MinIO + Trino + Doris OLAP + Airbyte 1.8 + dbt RPC + OpenMetadata + Temporal)

## 快速开始
```bash
# 首次初始化（内置 Postgres）
./init.sh single 'Strong@2025!'

# 或交互式执行
./init.sh
```

- 所有镜像版本集中在 `imgversion.conf`，修改后再跑 `init.sh` 即可生效。
- `init.sh` 会生成 `.env`、在单机模式下自签 TLS 证书，并启动对应 `docker-compose*.yml`。
- `start.sh` / `stop.sh`：常规启动与停止（默认读取 `init.sh` 记录的部署模式）。

## 目录
- `docker-compose.yml`：single（内置 Postgres）
- `docker-compose.ha2.yml`：外部 Postgres
- `docker-compose.cluster.yml`：外部 Postgres（可按需扩展）
- `imgversion.conf`：镜像版本集中管理
- `services/<service>/init`：每个镜像的初始化脚本（如 `services/yts-pg/init/10-init-users.sh`、`services/yts-minio-init/init/init.sh`）
- `services/<service>/data`：对应镜像的数据目录（如 `services/certs`、`services/yts-minio/data`）
- `services/yts-trino/init/catalog/doris.properties`：Trino 通过 MySQL 协议接入 Doris 的 Catalog
- `yts-nessie`：基于 Apache Nessie 的表版本服务，替换原先的 Hive Metastore
- `services/yts-ranger/`：Apache Ranger 管理端持久化目录
- `services/yts-dbt/`：dbt RPC 服务配置与示例项目
- `services/yts-doris/`：Doris FE / BE / Broker 的持久化目录与说明
- `init.sh`：一键初始化脚本
- `start.sh` / `stop.sh`：启动、停止 docker compose 服务

## 重要变量
- 域名：`BASE_DOMAIN`（默认 `yst.local`），各子域在 `.env` 自动生成。
- 数据卷：`services/yts-pg/data`、`services/yts-minio/data`、`services/yts-om-es/data`、`services/yts-airbyte-server/data/workspace`、`services/yts-dbt/logs`、`services/yts-doris/fe/meta`、`services/yts-doris/be/storage` 等（已预置目录并放宽权限以跑通，建议后续按需收紧）。
- Nessie：`HOST_NESSIE`（默认 `nessie.${BASE_DOMAIN}`），通过 Traefik 暴露在 19120 端口的 REST API。
- dbt 相关变量：`HOST_DBT`（默认 `dbt.${BASE_DOMAIN}`）、`DBT_RPC_PORT`、`DBT_TRINO_*`（默认指向内置 Trino，可按需改成外部仓库）。
- Doris 相关变量：`HOST_DORIS`（默认 `doris.${BASE_DOMAIN}`）、`DORIS_HTTP_PORT`（默认 8030，用于 FE Web UI / REST）、`DORIS_MYSQL_PORT`（默认 9030，FE MySQL 协议入口）、`DORIS_FE_EDIT_LOG_PORT`（默认 9010）、`DORIS_FE_RPC_PORT`（默认 9020）、`DORIS_BE_WEB_PORT`（默认 8040）、`DORIS_BE_HEARTBEAT_PORT`（默认 9050）、`DORIS_BE_BRPC_PORT`（默认 9060）、`DORIS_BROKER_PORT`（默认 8000）。

## 模式说明
- `single`：包含 `yts-pg`，本地持久化。
- `ha2` / `cluster`：不包含 `yts-pg`，请在 `.env` 中设置 `PG_HOST` 指向外部 Postgres（`init.sh` 默认写入 `your-external-pg-host`，启动前请改为真实地址）。

## 常见问题
- Postgres 认证失败：确认 `.env` 的 `PG_*` 与 `services/yts-pg/init/10-init-users.sh` 中的逻辑一致；首次启动务必清空 `services/yts-pg/data`。
- Airbyte 1.8 起不再需要 webapp 容器，UI 与 API 由 server 暴露（本包已对齐）。`INTERNAL_API_HOST`/`WORKLOAD_API_HOST` 必须是容器内可达的绝对 URL，以 `/` 结尾。

## dbt RPC 服务
- 使用镜像 `ghcr.io/dbt-labs/dbt-trino:1.8.6`，随栈一起启动 `dbt rpc`，默认暴露在 `https://${HOST_DBT}`（Traefik 转发到 `${DBT_RPC_PORT}`）。
- `services/yts-dbt/project/` 内置一个最小化 dbt 项目，可直接扩展模型与宏。`profiles.yml` 默认读取 `DBT_TRINO_*` 环境变量并连接到内置 Trino。
- Airbyte/Airflow 可通过 HTTP `POST /jsonrpc` （容器内地址 `http://yts-dbt:${DBT_RPC_PORT}/jsonrpc`）触发 dbt task，适合作为 ELT 流水线的 Transform 步骤。

## Doris OLAP 数仓
- FE、BE、Broker 分别使用镜像 `apache/doris:2.1.7-fe-x86_64` / `apache/doris:2.1.7-be-x86_64` / `apache/doris:2.1.7-broker-x86_64`。
- FE 通过 Traefik 暴露 Web UI：`https://${HOST_DORIS}`（80**30** → 443），MySQL 协议在 `yts-doris-fe:${DORIS_MYSQL_PORT}`，供 Trino/Airbyte/外部工具接入。
- FE 元数据与日志持久化在 `services/yts-doris/fe/*`，BE 存储位于 `services/yts-doris/be/storage`。
