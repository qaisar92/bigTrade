from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Application configuration loaded from environment variables."""

    # Database
    database_url: str = "postgresql+psycopg://admin:admin123@localhost:5432/bot_trading"
    database_pool_size: int = 10
    database_max_overflow: int = 20

    # Logging
    log_level: str = "INFO"

    # API
    api_host: str = "127.0.0.1"
    api_port: int = 8000

    class Config:
        # Don't load .env for this app to avoid conflicts with other DB URLs
        case_sensitive = False
        extra = "ignore"


settings = Settings()
