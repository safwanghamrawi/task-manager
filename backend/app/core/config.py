"""Application configuration.

Every value is sourced from the environment so that a single immutable image
can be promoted across environments without a rebuild. No secret has a usable
default: the database URL is required and the process refuses to start without
it.
"""

import json
from functools import lru_cache
from typing import Annotated, Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime settings, populated from environment variables."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # --- Application -----------------------------------------------------
    app_name: str = "task-manager-api"
    environment: Literal["local", "development", "staging", "production"] = "local"
    debug: bool = False
    log_level: str = "INFO"
    root_path: str = ""

    # --- Database --------------------------------------------------------
    # Async driver, e.g. postgresql+asyncpg://user:password@postgres:5432/tasks
    database_url: str = Field(..., description="SQLAlchemy async database URL")
    db_pool_size: int = 10
    db_max_overflow: int = 5
    db_pool_timeout: int = 10
    db_pool_recycle: int = 1800
    db_echo: bool = False

    # Startup resilience: Postgres may still be booting when the API starts.
    db_connect_max_attempts: int = 30
    db_connect_backoff_seconds: float = 1.0

    # Create tables on startup. Convenient here; production should disable
    # this and run Alembic migrations as a separate, ordered job.
    db_auto_create_schema: bool = True

    # --- HTTP ------------------------------------------------------------
    # NoDecode: without it pydantic-settings tries to JSON-decode the raw
    # environment value before the validator below can normalise it, so an
    # empty or comma-separated CORS_ORIGINS would abort startup.
    cors_origins: Annotated[list[str], NoDecode] = Field(default_factory=list)
    max_tasks: int = 10_000

    @field_validator("cors_origins", mode="before")
    @classmethod
    def _split_origins(cls, value: object) -> object:
        """Accept a comma-separated string as well as a JSON list.

        Decoding happens here rather than in pydantic-settings (see NoDecode
        above), so both notations have to be handled explicitly.
        """
        if isinstance(value, str):
            stripped = value.strip()
            if not stripped:
                return []
            if stripped.startswith("["):
                decoded: object = json.loads(stripped)
                return decoded
            return [origin.strip() for origin in stripped.split(",") if origin.strip()]
        return value

    @field_validator("log_level")
    @classmethod
    def _upper_log_level(cls, value: str) -> str:
        return value.upper()

    @property
    def is_production(self) -> bool:
        return self.environment == "production"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return the cached settings singleton."""
    return Settings()
