"""Prove the mock is spec-conformant: every response validates against the
schema the contract declares for it.

For each operation with a 2xx JSON body, call the mock and validate the
returned body against that operation's response schema (with $refs resolved
against the spec). Also spot-check a couple of semantic invariants.

    python test_conformance.py        # report; non-zero exit on any failure
"""
from __future__ import annotations

import sys

from fastapi.testclient import TestClient
from jsonschema import Draft7Validator, RefResolver

import app as app_mod
import xymon
from example import success_response

_METHODS = {"get", "post", "put", "patch", "delete"}

# Synthetic board so the real read handlers work without a Xymon server.
_BOARD = "\n".join([
    "db01|disk|red|1700000000",
    "db01|conn|green|1700000000",
    "web01|http|yellow|1700000100",
])


def main() -> int:
    xymon.xymondboard = lambda: _BOARD              # type: ignore
    xymon.rrd_xport = lambda args: (                # type: ignore
        '{"meta":{"start":1700000000,"step":300},"data":[[1.0],[2.0]]}')
    xymon.fetch_graph = lambda url: (b"\x89PNG mock", "image/png")  # type: ignore
    spec = app_mod.load_spec()
    base = (spec.get("servers") or [{}])[0].get("url", "").rstrip("/")
    client = TestClient(app_mod.build_app(spec))
    resolver = RefResolver.from_schema(spec)

    checked = failed = 0
    for path, item in spec["paths"].items():
        url = base + path.replace("{id}", "sample").replace("{host}", "web1")
        for method, op in item.items():
            if method not in _METHODS:
                continue
            code, schema = success_response(op)
            r = client.request(method.upper(), url)
            tag = f"{method.upper():6} {path}"
            if r.status_code != int(code):
                print(f"  ❌ {tag}: status {r.status_code} != {code}")
                failed += 1
                continue
            checked += 1
            if schema is None:
                print(f"  ✅ {tag} -> {code} (no body)")
                continue
            try:
                Draft7Validator(schema, resolver=resolver).validate(r.json())
                print(f"  ✅ {tag} -> {code} body conforms")
            except Exception as exc:                       # noqa: BLE001
                first = str(exc).splitlines()[0]
                print(f"  ❌ {tag}: body violates schema: {first}")
                failed += 1

    # Semantic spot-checks on the observed read plane.
    states = client.get(base + "/states").json()["items"]
    ok = states and states[0]["verdict"] in \
        spec["components"]["schemas"]["Status"]["enum"]
    health = client.get(base + "/health").json()
    ok &= isinstance(health.get("alive"), bool)
    print(f"\nspot-check: states[0].verdict valid + /health.alive bool -> "
          f"{'✅' if ok else '❌'}")

    total = checked + failed
    print(f"\n{checked}/{total} operations conformant, {failed} failure(s)")
    return 0 if failed == 0 and ok else 1


if __name__ == "__main__":
    sys.exit(main())
