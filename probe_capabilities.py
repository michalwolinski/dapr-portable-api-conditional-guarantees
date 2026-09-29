#!/usr/bin/env python3
"""Ask the sidecar what each state store can actually do, then decide."""
import json
import sys
import urllib.request

DAPR = "http://localhost:3500"

REQUIRED = {
    "transactions": "TRANSACTIONAL",
    "etags": "ETAG",
    "query": "QUERY_API",
}


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
        print(f"{name}: {sorted(capabilities) or ['(none advertised)']}")
        for feature, flag in REQUIRED.items():
            present = flag in capabilities
            print(f"    {feature:<13} {'yes' if present else 'NO'}")
            failed = failed or not present

    if failed:
        # Refuse to start rather than discover this on the first
        # multi-key write in production.
        print("\nrefusing to start: a configured store is missing a required capability")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
