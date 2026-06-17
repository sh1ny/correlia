from __future__ import annotations

from typing import Final, Literal

RouteClass = Literal["operator", "ingress", "metrics", "readyz", "health"]

ROUTE_CLASS_PREFIXES: Final[tuple[tuple[str, RouteClass], ...]] = (
    ("/v1/icinga2/events", "ingress"),
    ("/v1/incidents", "operator"),
    ("/v1/rules", "operator"),
    ("/v1/topology", "operator"),
    ("/v1/plugins", "operator"),
    ("/v1/metrics", "metrics"),
    ("/v1/readyz", "readyz"),
    ("/v1/health", "health"),
)


def classify_path(path: str) -> RouteClass:
    for prefix, route_class in ROUTE_CLASS_PREFIXES:
        if path == prefix or path.startswith(prefix + "/"):
            return route_class
    if path.startswith("/v1"):
        return "operator"
    return "operator"
