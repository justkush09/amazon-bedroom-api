# Bedroom Products API

Production-ready backend that imports bedroom-category products from the
**official Amazon Product Advertising API (PA-API 5.0)** into a normalized
PostgreSQL database, and exposes them through a REST API.

No web scraping is used anywhere — all data comes from signed, authenticated
calls to Amazon's PA-API `SearchItems` operation.

## Stack

- Python 3.12
- FastAPI + Uvicorn
- PostgreSQL 16
- SQLAlchemy 2.0 (async, `Mapped`/`mapped_column` style)
- Alembic (async migrations)
- Pydantic v2
- httpx (async HTTP client, used for signed PA-API calls)
- Docker / docker-compose

## Architecture

```
app/
  core/        # settings, logging, async DB engine/session
  models/      # SQLAlchemy ORM models (6 normalized tables)
  schemas/     # Pydantic v2 request/response models
  repositories/# data-access layer (category/subcategory/product)
  services/    # PA-API client (AWS SigV4 signing) + import orchestration
  api/routes/  # FastAPI routers, one file per resource
  utils/       # shared exceptions
alembic/       # async migration environment + versions
```

Clean separation: routes never touch the ORM directly, they call
repositories; the import service composes the PA-API client with the
repositories and owns transaction/commit boundaries.

## Database schema

- **categories** — top-level bedroom categories (Beds, Wardrobes, ...)
- **subcategories** — search-keyword-driven subcategories per category
- **products** — one row per ASIN (unique), FK to category/subcategory
- **product_images** — 1:N images per product
- **product_features** — 1:N bullet features per product
- **product_specifications** — 1:N key/value spec rows per product

`products.asin` is unique — imports **upsert by ASIN**: new ASINs are
inserted, existing ASINs get every field (price, rating, images, etc.)
refreshed in place.

## Setup

### 1. Get PA-API credentials

You need an approved Amazon Associates account with PA-API access:
- Access Key, Secret Key (from https://webservices.amazon.com/paapi5/documentation/)
- Partner Tag (your Associates tracking ID)
- The correct `PAAPI_HOST` / `PAAPI_REGION` / `PAAPI_MARKETPLACE` for your locale
  (e.g. `webservices.amazon.com` / `us-east-1` / `www.amazon.com` for the US).

### 2. Configure environment

```bash
cp .env.example .env
# edit .env with your PA-API credentials and DB settings
```

### 3. Run with Docker

```bash
docker compose up --build
```

This starts PostgreSQL, waits for it to be healthy, **runs Alembic
migrations automatically**, then starts the API on http://localhost:8000
(interactive docs at `/docs`).

### 4. Trigger an import

```bash
curl -X POST http://localhost:8000/import \
  -H "Content-Type: application/json" \
  -d '{"categories": ["Beds", "Mattresses"], "items_per_subcategory": 10}'
```

Omit the body (or pass `{}`) to import all 15 bedroom categories.

## API Reference

| Method | Path                  | Description                                      |
|--------|-----------------------|---------------------------------------------------|
| POST   | `/import`             | Fetch from PA-API and upsert into PostgreSQL       |
| GET    | `/products`           | Paginated list, with filters + sorting             |
| GET    | `/products/{id}`      | Full product detail (images, features, specs)      |
| GET    | `/categories`          | All categories with product counts                  |
| GET    | `/subcategories`       | All subcategories, optional `?category_id=`         |
| GET    | `/search?q=`           | Full-text-ish search over title/brand/description  |
| GET    | `/stats`               | Aggregate stats (counts, avg price/rating, brands)  |
| GET    | `/health`              | Liveness + DB connectivity check                    |

### `GET /products` query params

`page`, `page_size`, `category_id`, `subcategory_id`, `brand`,
`min_price`, `max_price`, `min_rating`, `in_stock`, `sort_by`
(`date_imported|current_price|rating|reviews_count|title`), `sort_dir` (`asc|desc`).

## Local development (without Docker)

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Start a local Postgres, then:
alembic upgrade head
uvicorn app.main:app --reload
```

## Notes on PA-API rate limits & error handling

- PA-API's default rate limit is roughly 1 request/second per account; the
  import service sleeps `PAAPI_REQUEST_DELAY_SECONDS` between subcategory
  calls and retries HTTP 429s with exponential backoff (`tenacity`).
- Every subcategory fetch and every individual item upsert is wrapped so
  one failure (bad item, API error) never aborts the whole import — failures
  are counted and returned in the `/import` response with error messages.
- Each subcategory's items are committed together as one batch, rather than
  committing per row, to reduce round-trips.
