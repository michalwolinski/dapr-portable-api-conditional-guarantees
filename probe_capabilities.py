#!/usr/bin/env python3
"""Ask the sidecar what each state store can actually do, then decide.

Requirements are declared PER STORE, because how a store is used decides what
it must guarantee: a store used as a cache and a store used as a system of
record do not need the same columns. An undeclared store also fails the check,
because a configured store nobody wrote a requirement for is a use nobody
agreed to.

    python3 probe_capabilities.py            # per-store requirements
    UNIFORM=1 python3 probe_capabilities.py  # the uniformity mistake, made explicit
"""
import json
import os
import sys
import urllib.request

DAPR = "http://localhost:3500"

# What THIS service asks of each store it uses.
REQUIRED_BY_STORE = {
    "statestore-redis": {"TRANSACTIONAL", "ETAG", "QUERY_API"},
    "statestore-memcached": {"TTL"},
}

if os.environ.get("UNIFORM"):
    # Assume every configured store needs every guarantee. This is the mistake
    # the article is about, and it is one line away - which is the point.
    union = set().union(*REQUIRED_BY_STORE.values())
    REQUIRED_BY_STORE = {name: set(union) for name in REQUIRED_BY_STORE}


def state_store_capabilities() -> dict[str, set[str]]:
    with urllib.request.urlopen(f"{DAPR}/v1.0/metadata", timeout=5) as response:
        metadata = json.load(response)

    stores: dict[str, set[str]] = {}
    for component in metadata["components"]:
        if not component["type"].startswith("state."):
            continue
        stores[component["name"]] = set(component.get("capabilities", []))
    return stores


def main() -> int:
    stores = state_store_capabilities()
    failed = False
    for name, capabilities in sorted(stores.items()):
        required = REQUIRED_BY_STORE.get(name)
        if required is None:
            # Configured but never declared: fail rather than guess.
            print(f"{name}: advertised {sorted(capabilities) or ['(nothing)']}")
            print("    configured but not declared in REQUIRED_BY_STORE")
            failed = True
            continue

        missing = required - capabilities
        print(f"{name}: advertised {sorted(capabilities) or ['(nothing)']}")
        print(f"    needs {sorted(required)}")
        print(f"    {'MISSING ' + str(sorted(missing)) if missing else 'ok'}")
        failed = failed or bool(missing)

    if failed:
        print("\nrefusing to start: a store cannot meet the requirements declared for it")
        return 2
    print("\nevery configured store meets the requirements declared for it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
