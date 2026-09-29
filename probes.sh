#!/usr/bin/env bash
# Probes the same state-management features against two state stores that
# Dapr lists as Stable, and adds one Redis-specific finding.
#
#   docker compose up -d
#   ./probes.sh 2>&1 | tee probes.log
#
# The point is not that one store is worse. It is that the API is identical
# and the guarantees are not - and that the two features fail differently:
# transactions refuse loudly, ETags are ignored silently on memcached.
set -u

DAPR="${DAPR:-http://localhost:3500}"
REDIS="$DAPR/v1.0/state/statestore-redis"
MEMCACHED="$DAPR/v1.0/state/statestore-memcached"
JSON='Content-Type: application/json'

reset_keys() { docker compose exec -T redis redis-cli --scan --pattern 'demo||probe*' 2>/dev/null | tr -d '\r' | while read -r k; do [ -n "$k" ] && docker compose exec -T redis redis-cli DEL "$k" >/dev/null; done; }
probe() { # label, then curl args
  local label="$1"; shift
  local body code
  body=$(mktemp)
  code=$(curl -s -o "$body" -w '%{http_code}' "$@")
  printf '  %-42s -> %s %s\n' "$label" "$code" "$(tr -d '\n' < "$body" | cut -c1-165)"
  rm -f "$body"
}
etag_of() { curl -s -D - -o /dev/null "$1" | awk 'tolower($1)=="etag:"{print $2}' | tr -d '\r'; }
hash_of() { docker compose exec -T redis redis-cli HGETALL "$1" 2>/dev/null | tr -d '\r' | paste - - - | sed 's/^/      /'; }
hr() { printf '\n=== %s ===\n' "$1"; }

reset_keys

hr "0. capabilities, as the runtime itself reports them"
curl -s "$DAPR/v1.0/metadata" | python3 -c 'import json,sys
d = json.load(sys.stdin)
for c in d["components"]:
    if c["type"].startswith("state."):
        print("  %-22s %s" % (c["name"], c.get("capabilities", [])))
print("  %-22s %s" % ("actorRuntime", d["actorRuntime"]["runtimeStatus"]))'

hr "1. single-key write - both stores do CRUD"
probe "redis"     -X POST "$REDIS"     -H "$JSON" -d '[{"key":"probe-basic","value":"hello"}]'
probe "memcached" -X POST "$MEMCACHED" -H "$JSON" -d '[{"key":"probe-basic","value":"hello"}]'

hr "2. multi-key transaction - one request, two stores"
TX='{"operations":[{"operation":"upsert","request":{"key":"probe-tx-a","value":"A"}},{"operation":"upsert","request":{"key":"probe-tx-b","value":"B"}}]}'
probe "redis"     -X POST "$REDIS/transaction"     -H "$JSON" -d "$TX"
probe "memcached" -X POST "$MEMCACHED/transaction" -H "$JSON" -d "$TX"

hr "3a. optimistic concurrency on redis (ETAG capable)"
probe "redis: write v1" -X POST "$REDIS" -H "$JSON" -d '[{"key":"probe-etag","value":"v1"}]'
E_R=$(etag_of "$REDIS/probe-etag")
printf '  %-42s -> %s\n' "redis: Etag header on read" "${E_R:-<none>}"
probe "redis: write, matching Etag + first-write" -X POST "$REDIS" -H "$JSON" \
  -d "[{\"key\":\"probe-etag\",\"value\":\"v2\",\"etag\":\"$E_R\",\"options\":{\"concurrency\":\"first-write\"}}]"
probe "redis: write, same Etag again (stale)" -X POST "$REDIS" -H "$JSON" \
  -d "[{\"key\":\"probe-etag\",\"value\":\"v3\",\"etag\":\"$E_R\",\"options\":{\"concurrency\":\"first-write\"}}]"
probe "redis: value after the stale write" "$REDIS/probe-etag"

hr "3b. the same requests on memcached (no ETAG capability)"
probe "memcached: write v1" -X POST "$MEMCACHED" -H "$JSON" -d '[{"key":"probe-etag","value":"v1"}]'
E_M=$(etag_of "$MEMCACHED/probe-etag")
printf '  %-42s -> %s\n' "memcached: Etag header on read" "${E_M:-<none>}"
probe "memcached: write, matching Etag + first-write" -X POST "$MEMCACHED" -H "$JSON" \
  -d '[{"key":"probe-etag","value":"v2","etag":"x","options":{"concurrency":"first-write"}}]'
probe "memcached: write, deliberately stale Etag" -X POST "$MEMCACHED" -H "$JSON" \
  -d '[{"key":"probe-etag","value":"v3","etag":"definitely-stale","options":{"concurrency":"first-write"}}]'
probe "memcached: value now" "$MEMCACHED/probe-etag"

hr "4. redis: what a 'first-write' request leaves behind"
probe "write v1, no concurrency option" -X POST "$REDIS" -H "$JSON" -d '[{"key":"probe-marker","value":"v1"}]'
echo "    hash fields:"
hash_of 'demo||probe-marker'
E=$(etag_of "$REDIS/probe-marker")
probe "write v2, first-write + matching Etag" -X POST "$REDIS" -H "$JSON" \
  -d "[{\"key\":\"probe-marker\",\"value\":\"v2\",\"etag\":\"$E\",\"options\":{\"concurrency\":\"first-write\"}}]"
echo "    hash fields after a SUCCESSFUL first-write:"
hash_of 'demo||probe-marker'
probe "now write v3 with NO Etag" -X POST "$REDIS" -H "$JSON" -d '[{"key":"probe-marker","value":"v3"}]'
probe "and again, NO Etag" -X POST "$REDIS" -H "$JSON" -d '[{"key":"probe-marker","value":"v4"}]'
probe "value is still (correctly) v2" "$REDIS/probe-marker"

hr "5. Query API - same request, both stores"
Q='{"filter":{"EQ":{"appid":"demo"}},"page":{"limit":5}}'
probe "redis"     -X POST "$DAPR/v1.0-alpha1/state/statestore-redis/query"     -H "$JSON" -d "$Q"
probe "memcached" -X POST "$DAPR/v1.0-alpha1/state/statestore-memcached/query" -H "$JSON" -d "$Q"

hr "6. pub/sub at-least-once redelivery"
CE='{"specversion":"1.0","type":"com.example.order.placed","source":"demo","id":"evt-4471","data":{"orderId":"ORD-4471"}}'
probe "publish one event" -X POST "$DAPR/v1.0/publish/pubsub-redis/orders" -H "$JSON" -d "$CE"
sleep 6
echo "    subscriber log (FAIL_FIRST=2):"
docker compose logs subscriber --tail=8 2>&1 | sed 's/^subscriber-1 *| /      /'
