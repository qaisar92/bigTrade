# Docker PostgreSQL Setup

Minimal Docker Compose setup for PostgreSQL and pgAdmin.

## Services

- PostgreSQL using the official `postgres:latest` image
- pgAdmin using the official `dpage/pgadmin4:latest` image

Both services run on the same Docker network. PostgreSQL and pgAdmin each use a persistent named volume.

## Start the stack

Run the services in detached mode:

```bash
docker compose up -d
```

To stop the services:

```bash
docker compose down
```

To stop the services and remove volumes as well:

```bash
docker compose down -v
```

## Access PostgreSQL

- Host: `localhost`
- Port: `5432`
- Database: `bot_trading`
- Username: `admin`
- Password: `admin123`

Example connection string:

```text
postgresql://admin:admin123@localhost:5432/bot_trading
```

## Access pgAdmin

- URL: `http://localhost:5050`
- Email: `admin@admin.com`
- Password: `admin123`
- Preconfigured server: `bot-trading-postgres`

Server connection details:

- Host name/address: `postgres`
- Port: `5432`
- Maintenance database: `bot_trading`
- Username: `admin`
- Password: `admin123`

## Environment variables

The Compose configuration reads database and pgAdmin credentials from `.env`.

Configured values:

```env
POSTGRES_USER=admin
POSTGRES_PASSWORD=admin123
POSTGRES_DB=bot_trading
POSTGRES_PORT=5432
PGADMIN_DEFAULT_EMAIL=admin@admin.com
PGADMIN_DEFAULT_PASSWORD=admin123
PGADMIN_PORT=5050
```

## Notes

- PostgreSQL data persists in the named Docker volume `postgres_data`.
- The PostgreSQL volume is mounted at `/var/lib/postgresql` to match the `postgres:latest` image layout used by PostgreSQL 18+.
- pgAdmin data persists in the named Docker volume `pgadmin_data`.
- `restart: unless-stopped` is enabled for both services for better operational resilience.