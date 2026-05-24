from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="COUNTER_", case_sensitive=False)

    backend: str = Field(default="memory", description="Persistence backend: memory or redis")
    redis_url: str = Field(default="redis://localhost:6379/0")
    redis_key: str = Field(default="counter:value")
    restart_key: str = Field(default="counter:restarts")
    log_level: str = Field(default="INFO")
    app_version: str = Field(default="0.2.0", description="Surfaced on GET / to demo CD updates")

    # Optional Postgres ingest sink (provisioned by the Crossplane XAppDatabase).
    # If COUNTER_INGEST_ENABLED=true and the conn vars below are set, /ingest
    # is wired up; otherwise the endpoint returns 503.
    ingest_enabled: bool = Field(default=False)
    pg_dsn: str = Field(default="", description="Full asyncpg DSN, or build from parts below")
    pg_host: str = Field(default="")
    pg_port: int = Field(default=5432)
    pg_database: str = Field(default="")
    pg_username: str = Field(default="")
    pg_password: str = Field(default="")
    pg_table: str = Field(default="events", description="Target table name inside the schema")
    pg_schema: str = Field(default="public")


def get_settings() -> Settings:
    return Settings()
