#!/bin/sh
set -eu

log() {
  printf '%s\n' "[pgadmin-bootstrap] $*"
}

/entrypoint.sh &
pgadmin_pid=$!

db_path="/var/lib/pgadmin/pgadmin4.db"
servers_path="/tmp/servers.json"
attempts=30

while [ "$attempts" -gt 0 ]; do
  if [ -f "$db_path" ]; then
    break
  fi
  attempts=$((attempts - 1))
  sleep 1
done

if [ ! -f "$db_path" ]; then
  log "pgAdmin configuration database was not created in time"
  exit 1
fi

cat > "$servers_path" <<EOF
{
  "Servers": {
    "1": {
      "Name": "${PGADMIN_SERVER_NAME}",
      "Group": "Servers",
      "Host": "postgres",
      "Port": 5432,
      "MaintenanceDB": "${POSTGRES_DB}",
      "Username": "${POSTGRES_USER}",
      "SSLMode": "prefer"
    }
  }
}
EOF

attempts=30
while [ "$attempts" -gt 0 ]; do
  if /venv/bin/python /pgadmin4/setup.py load-servers "$servers_path" --user "$PGADMIN_DEFAULT_EMAIL" --replace >/tmp/load-servers.log 2>&1; then
    log "Preconfigured server imported"
    break
  fi
  attempts=$((attempts - 1))
  sleep 1
done

if [ "$attempts" -eq 0 ]; then
  cat /tmp/load-servers.log
  log "Server import failed"
  exit 1
fi

wait "$pgadmin_pid"