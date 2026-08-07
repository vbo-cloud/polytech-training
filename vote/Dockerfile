FROM python:3.12-slim
WORKDIR /app
# python:3.12-slim ships no unprivileged user, so create one. Kept above
# COPY . . because it is a stable layer a code change must not re-run.
RUN useradd --create-home --uid 1000 appuser
# /app belongs to root and appuser cannot write .pyc files there. Python
# swallows that failure silently and recompiles on every import instead.
ENV PYTHONDONTWRITEBYTECODE=1
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
# After the installs: pip needs root, and the dependencies must stay owned by
# root so the running app cannot rewrite them.
USER appuser
# 8000, not 80: ports below 1024 are privileged on Linux and gunicorn can no
# longer bind them as appuser. EXPOSE states the new contract for everything
# that does not read compose.yaml.
EXPOSE 8000
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "app:app"]
