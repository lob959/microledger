import json
import logging
import os
from datetime import datetime, timezone


class StructuredJSONFormatter(logging.Formatter):
    """
    Formats log records as structured JSON.
    Every field is queryable in CloudWatch Log Insights.

    Usage:
        logger.info("Transaction created", extra={"transaction_id": "abc", "amount": 100})
    """

    # Standard LogRecord attributes we don't want to duplicate in the output
    RESERVED_ATTRS = {
        "args", "asctime", "created", "exc_info", "exc_text", "filename",
        "funcName", "levelname", "levelno", "lineno", "message", "module",
        "msecs", "msg", "name", "pathname", "process", "processName",
        "relativeCreated", "stack_info", "thread", "threadName",
        "taskName",
    }

    def format(self, record: logging.LogRecord) -> str:
        log_entry = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(),
            "level": record.levelname,
            "service": os.getenv("SERVICE_NAME", "microledger"),
            "logger": record.name,
            "message": record.getMessage(),
        }

        # Merge any extra={} fields passed by the caller
        extra_fields = {
            k: v for k, v in record.__dict__.items()
            if k not in self.RESERVED_ATTRS
        }
        log_entry.update(extra_fields)

        if record.exc_info:
            log_entry["exception"] = self.formatException(record.exc_info)

        # default=str handles Decimal, UUID, datetime etc. gracefully
        return json.dumps(log_entry, default=str)


def get_logger(name: str) -> logging.Logger:
    logger = logging.getLogger(name)

    if not logger.handlers:
        level = os.getenv("LOG_LEVEL", "INFO").upper()
        logger.setLevel(level)
        handler = logging.StreamHandler()
        handler.setFormatter(StructuredJSONFormatter())
        logger.addHandler(handler)
        logger.propagate = False

    return logger
