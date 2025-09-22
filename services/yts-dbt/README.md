# yts-dbt Service

This directory holds the dbt RPC service configuration and a starter project that targets the bundled Trino cluster.

- `project/`: dbt project skeleton. Extend models/macros/tests here.
- `profiles/`: default `profiles.yml` that reads Trino connection details from environment variables.
- `logs/`: mounted into `/root/.dbt/logs` for persistent RPC/server logs.

The container starts `dbt rpc` so that orchestrators such as Airbyte or Airflow can trigger runs through HTTP (`/jsonrpc`).
