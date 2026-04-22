# syntax=docker/dockerfile:1.7

# ---------- builder ----------
FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim AS builder
WORKDIR /app

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never

COPY pyproject.toml uv.lock README.md ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# ---------- runtime ----------
FROM python:3.13-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid 10001 --no-create-home --shell /sbin/nologin app

WORKDIR /app

COPY --from=builder --chown=10001:10001 /app/.venv /app/.venv
COPY --chown=10001:10001 gsc_server.py ./

# gsc_server.py does os.makedirs(_CONFIG_DIR) at module load. Default
# platformdirs.user_config_dir("mcp-gsc") = $HOME/.config/mcp-gsc, and
# our non-root user has no writable home (useradd --no-create-home).
# Point GSC_CONFIG_DIR at a dir we own explicitly.
RUN mkdir -p /app/.config/mcp-gsc && chown -R 10001:10001 /app/.config

ENV PATH="/app/.venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    MCP_TRANSPORT=streamable-http \
    MCP_HOST=0.0.0.0 \
    MCP_PORT=3001 \
    MCP_PATH=/mcp \
    GSC_CONFIG_DIR=/app/.config/mcp-gsc \
    GSC_SKIP_OAUTH=true \
    GSC_DATA_STATE=all \
    GSC_ALLOW_DESTRUCTIVE=false

EXPOSE 3001

USER 10001:10001

# Tolerant healthcheck: MCP streamable-http returns 400/405/406 for naive GET
# without the right Accept headers. 401 appears when MCP_BEARER_TOKEN is set
# and the healthcheck itself has no token — still means "process is alive".
# Any of those codes = healthy. 5xx / timeout = really broken.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS -o /dev/null -w "%{http_code}" http://localhost:3001/mcp \
        | grep -qE "^(200|400|401|405|406)$" || exit 1

CMD ["python", "gsc_server.py"]
