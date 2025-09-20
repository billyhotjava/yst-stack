# YTS Big Data Stack (Traefik + Keycloak + MinIO + Hive/Trino + Airbyte 1.8 + OpenMetadata + Temporal)

## 快速开始
```bash
# 单机（内置 Postgres）
./start.sh single 'Strong@2025!'

# 或交互式执行
./start.sh
```

- 所有镜像版本集中在 `imgversion.conf`，修改后再跑 `start.sh` 即可生效。
- `start.sh` 会生成 `.env`、在单机模式下自签 TLS 证书，并启动对应 `docker-compose*.yml`。

## 目录
- `docker-compose.yml`：single（内置 Postgres）
- `docker-compose.ha2.yml`：外部 Postgres
- `docker-compose.cluster.yml`：外部 Postgres（可按需扩展）
- `imgversion.conf`：镜像版本集中管理
- `services/<service>/init`：每个镜像的初始化脚本（如 `services/yts-pg/init/10-init-users.sh`、`services/yts-minio-init/init/init.sh`）
- `services/<service>/data`：对应镜像的数据目录（如 `services/yts-proxy/data/certs`、`services/yts-minio/data`）
- `services/yts-trino/init/catalog/hive.properties`：Trino Hive Catalog
- `start.sh`：一键启动脚本

## 重要变量
- 域名：`BASE_DOMAIN`（默认 `yts.local`），各子域在 `.env` 自动生成。
- 数据卷：`services/yts-pg/data`、`services/yts-minio/data`、`services/yts-om-es/data`、`services/yts-airbyte-server/data/workspace` 等（已预置目录并放宽权限以跑通，建议后续按需收紧）。

## 模式说明
- `single`：包含 `yts-pg`，本地持久化。
- `ha2` / `cluster`：不包含 `yts-pg`，请在 `.env` 中设置 `PG_HOST` 指向外部 Postgres（`start.sh` 默认写入 `your-external-pg-host`，启动前请改为真实地址）。

## 常见问题
- Postgres 认证失败：确认 `.env` 的 `PG_*` 与 `services/yts-pg/init/10-init-users.sh` 中的逻辑一致；首次启动务必清空 `services/yts-pg/data`。
- Airbyte 1.8 起不再需要 webapp 容器，UI 与 API 由 server 暴露（本包已对齐）。`INTERNAL_API_HOST`/`WORKLOAD_API_HOST` 必须是容器内可达的绝对 URL，以 `/` 结尾。
