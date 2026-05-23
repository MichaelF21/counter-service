from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="COUNTER_", case_sensitive=False)

    backend: str = Field(default="memory", description="Persistence backend: memory or redis")
    redis_url: str = Field(default="redis://localhost:6379/0")
    redis_key: str = Field(default="counter:value")
    restart_key: str = Field(default="counter:restarts")
    log_level: str = Field(default="INFO")
    app_version: str = Field(default="0.1.0", description="Surfaced on GET / to demo CD updates")


def get_settings() -> Settings:
    return Settings()
