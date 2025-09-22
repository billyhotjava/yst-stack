# yts-ranger Service

This directory holds persistent assets for the Apache Ranger admin container. The Bitnami-based image stores mutable state under `/bitnami/ranger`, which is volume-mounted to ensure policies and audit settings survive restarts:

- `admin/data` → `/bitnami/ranger/data`
- `admin/logs` → `/bitnami/ranger/logs`

Additional configuration snippets (for example, custom `ranger-admin-site.xml` overrides) can be dropped under `admin/conf` and mounted from the compose file if needed.
