#!/bin/sh
set -e

echo "Waiting for database..."
python -c "
import asyncio, os, sys, asyncpg, urllib.parse as up

async def wait():
    url = os.environ['DATABASE_URL'].replace('+asyncpg', '')
    for attempt in range(30):
        try:
            conn = await asyncpg.connect(url)
            await conn.close()
            print('Database is ready.')
            return
        except Exception as e:
            print(f'DB not ready ({attempt+1}/30): {e}')
            await asyncio.sleep(2)
    sys.exit('Database never became ready.')

asyncio.run(wait())
"

echo "Running database migrations..."
alembic upgrade head

echo "Starting application..."
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers "${UVICORN_WORKERS:-2}"
