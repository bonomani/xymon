"""Generate spec-conformant example values from the OpenAPI schemas.

The mock returns, for each operation, the success response's declared
``example`` when the author provided one (the spec is rich in these), and
otherwise synthesises a minimal value that satisfies the response schema. Both
paths are conformant by construction; ``test_conformance.py`` proves it with
jsonschema.
"""
from __future__ import annotations

from typing import Any

_SUCCESS = ("200", "201", "202", "203", "204")
_REF = "#/components/schemas/"


def _resolve(schema: dict, spec: dict) -> dict:
    ref = schema.get("$ref")
    if ref and ref.startswith(_REF):
        return spec["components"]["schemas"][ref[len(_REF):]]
    return schema


def from_schema(schema: dict, spec: dict, depth: int = 0) -> Any:
    """A minimal value satisfying ``schema`` (cycle/recursion-guarded)."""
    schema = _resolve(schema or {}, spec)
    if "example" in schema:
        return schema["example"]
    for comb in ("allOf", "oneOf", "anyOf"):
        if comb in schema and schema[comb]:
            return from_schema(schema[comb][0], spec, depth + 1)
    if "enum" in schema:
        return schema["enum"][0]

    typ = schema.get("type")
    if typ == "object" or "properties" in schema or "additionalProperties" in schema:
        if depth > 6:                                   # guard cyclic refs
            return {}
        out: dict[str, Any] = {}
        for name, sub in (schema.get("properties") or {}).items():
            out[name] = from_schema(sub, spec, depth + 1)
        addl = schema.get("additionalProperties")
        if isinstance(addl, dict) and not out:
            out["sample"] = from_schema(addl, spec, depth + 1)
        return out
    if typ == "array":
        return [from_schema(schema.get("items") or {}, spec, depth + 1)]
    if typ == "string":
        return "2026-01-01T00:00:00Z" if schema.get("format") == "date-time" \
            else "string"
    if typ == "integer":
        return schema.get("minimum", 1)
    if typ == "number":
        return 1.0
    if typ == "boolean":
        return True
    return None


def success_response(op: dict) -> tuple[str, dict | None]:
    """Return (status_code, json_schema_or_None) for an operation's success."""
    responses = op.get("responses", {})
    for code in _SUCCESS:
        if code in responses:
            content = (responses[code] or {}).get("content", {})
            schema = content.get("application/json", {}).get("schema")
            return code, schema
    # default to 200 with no body
    return "200", None


def success_example(op: dict, spec: dict) -> tuple[int, Any]:
    """(status_code, body) for an operation's success response."""
    code, schema = success_response(op)
    if schema is None:
        return int(code), None
    # Prefer an author-provided example on the response object itself.
    for c in _SUCCESS:
        resp = (op.get("responses", {}).get(c) or {})
        appjson = resp.get("content", {}).get("application/json", {})
        if "example" in appjson:
            return int(c), appjson["example"]
    return int(code), from_schema(schema, spec)
