from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram

registry = CollectorRegistry()

http_requests_total = Counter(
    "counter_http_requests_total",
    "HTTP requests served by the counter service.",
    ["method", "endpoint", "status"],
    registry=registry,
)

http_request_duration_seconds = Histogram(
    "counter_http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["method", "endpoint"],
    registry=registry,
)

counter_value = Gauge(
    "counter_value",
    "Current value of the counter.",
    registry=registry,
)

restart_count = Gauge(
    "counter_restart_count",
    "Number of pod restarts since the counter store was last reset.",
    registry=registry,
)
