.PHONY: test lint typecheck run

test:
	uv run pytest

lint:
	uv run ruff check .

typecheck:
	uv run mypy app

run:
	uv run uvicorn app.main:create_app --factory --reload
