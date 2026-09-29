# Dapr: a portable API over non-portable guarantees

Reproducible demo for the article of the same name. It runs the *same*
state-management requests against two stores that Dapr lists as **Stable**,
and against one Redis-specific behaviour that the API does not warn about.

Nothing here needs a cluster or the Dapr CLI. `daprd` runs standalone in a
container with the components mounted from `./components`.

## Versions (pinned, verified to exist)

| Component | Tag | Why this one |
|---|---|---|
| `daprio/daprd` | `1.18.4` | latest stable; `1.18.5` was only an RC at the time of writing |
| `redis` | `8.10.2` | state store *with* ETag + transactions |
| `memcached` | `1.6.45` | state store *without* them, still marked Stable |
| `node` | `22.23.3-alpine` | runs the pub/sub subscriber |

## Run it

```bash
docker compose up -d
./probes.sh 2>&1 | tee probes.log
docker compose down -v
```

`probes.log` is the captured output of the run this article is based on.

## What the probes show

1. **Capabilities as the runtime reports them.** `GET /v1.0/metadata` lists
   what each store actually advertises:

   - `statestore-memcached` → `["TTL"]`
   - `statestore-redis` → `["ETAG", "TRANSACTIONAL", "TTL", "QUERY_API", "KEYS_LIKE", "ACTOR"]`

2. **CRUD works on both.** The identical request returns `204` on each.

3. **Transactions fail loudly.** The same multi-key `…/transaction` request
   returns `204` on Redis and `500 ERR_STATE_STORE_NOT_SUPPORTED` on
   memcached, with a message that says the store does not support transactions.

4. **ETags fail silently.** On Redis, reading a key returns an `Etag` header,
   a matching ETag gives `204`, and the same ETag again gives `409` — the
   value is not clobbered. On memcached there is **no `Etag` header at all**,
   and a write carrying a deliberately stale ETag still returns `204` and
   overwrites the value. The parameter is accepted and ignored.

5. **A Redis foot-gun the API does not mention.** After any write that uses
   `"options": {"concurrency": "first-write"}`, Dapr leaves a `first-write`
   field on the Redis hash:

   ```
   data  "v2"   version  2   first-write  0     <- after a successful first-write
   data  "v1"   version  1                       <- after a plain write
   ```

   From then on, writes to that key **without** an ETag fail with
   `500 ERR_STATE_SAVE` (a Lua script error) and the stored value silently
   stays old. Writes that supply the ETag they just read keep working. See
   the neighbouring reports: dapr/dapr#2619 (mismatch originally returned 500,
   now 409) and dapr/components-contrib#1010 (first-write with no ETag).

6. **The Query API is listed, not configured.** Redis advertises `QUERY_API`
   yet the first query fails with `ERR_STATE_QUERY: query index not found`
   until `queryIndexes` is configured and the index exists. memcached fails
   with `ERR_STATE_STORE_NOT_SUPPORTED: state store does not support querying`.

7. **Pub/sub redelivers.** One publish, and the subscriber (which fails its
   first two deliveries on purpose) logs the **same event id three times**,
   one second apart — the interval comes from the resiliency policy in
   `components/resiliency-pubsub.yaml`, not from the API.

## Layout

```
docker-compose.yml                      redis, memcached, subscriber, daprd
components/statestore-redis.yaml        state.redis
components/statestore-memcached.yaml    state.memcached
components/pubsub-redis.yaml            pubsub.redis
components/resiliency-pubsub.yaml       explicit 1s retry policy
app/server.js                           subscriber; FAIL_FIRST=2
probes.sh                               the whole suite, idempotent
probes.log                              captured output
```
