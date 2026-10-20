from typing import Any

from codex_inspector.core.config_merge import redact_secrets
from codex_inspector.core.mcp_scan import scan_mcp_servers


def test_custom_headers_and_environment_values_are_redacted() -> None:
    config: dict[str, Any] = {
        "mcp_servers": {
            "example": {
                "command": "example-server",
                "http_headers": {"X-Custom-Access": "example-private-value"},
                "env": {"CUSTOM_ACCESS": "example-private-value", "PORT": 1234},
            }
        }
    }
    redacted = redact_secrets(config)
    server = redacted["mcp_servers"]["example"]
    assert server["command"] == "example-server"
    assert server["http_headers"]["X-Custom-Access"] == "***redacted***"
    assert server["env"] == {
        "CUSTOM_ACCESS": "***redacted***",
        "PORT": "***redacted***",
    }
    assert (
        config["mcp_servers"]["example"]["http_headers"]["X-Custom-Access"]
        == "example-private-value"
    )


def test_mcp_report_uses_redacted_values() -> None:
    config = {
        "mcp_servers": {"example": {"headers": {"X-Custom": "example-private-value"}}}
    }
    servers = scan_mcp_servers(redact_secrets(config))
    assert servers[0].raw["headers"]["X-Custom"] == "***redacted***"


def test_regular_configuration_values_remain_visible() -> None:
    assert redact_secrets(
        {"model": "example-model", "args": ["serve"], "enabled": True}
    ) == {
        "model": "example-model",
        "args": ["serve"],
        "enabled": True,
    }
