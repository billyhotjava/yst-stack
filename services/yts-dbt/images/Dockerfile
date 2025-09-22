# 基础镜像：官方 Python（3.11 与 dbt-core 1.9.x 兼容）
FROM python:3.11-slim

# 环境准备
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    # 让 dbt 默认在 /workspace/.dbt 查找 profiles.yml（可在 compose 中用 volume 覆盖）
    DBT_PROFILES_DIR=/workspace/.dbt

# 可选：国内换源（需要时取消注释）
RUN pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple

# 系统依赖（dbt/编译常用）并清理缓存
RUN apt-get update && apt-get install -y --no-install-recommends \
      git gcc build-essential \
      libpq-dev openssl ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# 升级 pip/setuptools/wheel，避免老版本构建问题
RUN python -m pip install --no-cache-dir --upgrade pip setuptools wheel

# 指定版本（与你项目兼容）；默认 1.9.3，如需切换可在 build 时传入 --build-arg
ARG DBT_CORE_VER=1.9.3
ARG DBT_TRINO_VER=1.9.3

# 从官方 PyPI 安装 dbt-core + dbt-trino
RUN pip install --no-cache-dir \
      "dbt-core==${DBT_CORE_VER}" \
      "dbt-trino==${DBT_TRINO_VER}"

# （可选）常见数据库驱动——按需打开
# RUN pip install --no-cache-dir psycopg2-binary==2.9.9

# 建议使用非 root 运行
RUN useradd -ms /bin/bash dbt && mkdir -p /workspace && chown -R dbt:dbt /workspace
USER dbt

WORKDIR /workspace

# dbt 默认入口
ENTRYPOINT ["dbt"]
# 常用：docker run ... dbt --version / dbt debug / dbt run 等
