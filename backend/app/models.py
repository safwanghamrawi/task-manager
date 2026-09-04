"""SQLAlchemy ORM models."""

from datetime import UTC, datetime

from sqlalchemy import DateTime, Index, Integer, String, Text, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


def _utcnow() -> datetime:
    return datetime.now(tz=UTC)


class Base(DeclarativeBase):
    """Declarative base for all ORM models."""


class Task(Base):
    """A single task owned by the task list."""

    __tablename__ = "tasks"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    completed: Mapped[bool] = mapped_column(
        # Boolean on Postgres, INTEGER on SQLite; SQLAlchemy handles both.
        default=False,
        nullable=False,
        server_default="false",
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=_utcnow,
        server_default=func.now(),
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=_utcnow,
        onupdate=_utcnow,
        server_default=func.now(),
        nullable=False,
    )

    # The list endpoint always sorts newest-first; without this index that is a
    # sequential scan plus a sort once the table grows.
    __table_args__ = (Index("ix_tasks_created_at_desc", created_at.desc()),)

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        return f"<Task id={self.id} title={self.title!r} completed={self.completed}>"
