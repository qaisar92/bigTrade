import logging
from pathlib import Path

_LOG_DIR = Path(__file__).resolve().parent.parent / "logs"
_LOG_FILE = _LOG_DIR / "ea_ingest.log"

_FORMATTER = logging.Formatter(
    "%(asctime)s | %(levelname)s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)


def get_logger(name: str = "ea_ingest") -> logging.Logger:
    """Return a named logger with file + stream handlers.

    Safe to call multiple times (e.g. after uvicorn --reload): handlers are
    added only when none exist yet on the logger.
    """
    logger = logging.getLogger(name)

    if logger.handlers:
        return logger

    logger.setLevel(logging.INFO)
    logger.propagate = False

    _LOG_DIR.mkdir(parents=True, exist_ok=True)

    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(_FORMATTER)
    logger.addHandler(stream_handler)

    file_handler = logging.FileHandler(_LOG_FILE, encoding="utf-8")
    file_handler.setFormatter(_FORMATTER)
    logger.addHandler(file_handler)

    return logger
