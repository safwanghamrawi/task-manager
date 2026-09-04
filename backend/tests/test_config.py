"""Settings parsing.

The CORS cases are a regression test: pydantic-settings JSON-decodes complex
types straight from the environment, which made an empty or comma-separated
``CORS_ORIGINS`` crash the process on startup.
"""

import pytest

from app.core.config import Settings

DSN = "postgresql+asyncpg://user:pw@postgres:5432/tasks"


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("", []),
        ("   ", []),
        ("http://localhost:3000", ["http://localhost:3000"]),
        ("http://a.test, http://b.test", ["http://a.test", "http://b.test"]),
        ('["http://a.test","http://b.test"]', ["http://a.test", "http://b.test"]),
    ],
)
def test_cors_origins_accepts_empty_csv_and_json(
    monkeypatch: pytest.MonkeyPatch, raw: str, expected: list[str]
) -> None:
    monkeypatch.setenv("DATABASE_URL", DSN)
    monkeypatch.setenv("CORS_ORIGINS", raw)

    assert Settings().cors_origins == expected


def test_database_url_is_required(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DATABASE_URL", raising=False)

    with pytest.raises(ValueError, match="database_url"):
        Settings(_env_file=None)


def test_log_level_is_normalised(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", DSN)
    monkeypatch.setenv("LOG_LEVEL", "debug")

    assert Settings().log_level == "DEBUG"


def test_unknown_environment_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", DSN)
    monkeypatch.setenv("ENVIRONMENT", "prod")  # not one of the allowed values

    with pytest.raises(ValueError, match="environment"):
        Settings()


def test_is_production_flag(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", DSN)
    monkeypatch.setenv("ENVIRONMENT", "production")

    assert Settings().is_production is True
