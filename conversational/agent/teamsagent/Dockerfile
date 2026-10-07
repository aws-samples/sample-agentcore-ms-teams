# Base image from Amazon ECR Public (Docker official python image mirror).
FROM public.ecr.aws/docker/library/python:3.12-slim-bookworm
WORKDIR /app

# uv was previously provided by the ghcr.io/astral-sh/uv base image; install a
# pinned version from PyPI instead so no external (non-ECR) registry is used.
RUN pip install --no-cache-dir uv==0.12.23

# All environment variables in one layer
ENV UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_NO_PROGRESS=1 \
    PYTHONUNBUFFERED=1 \
    DOCKER_CONTAINER=1



COPY pyproject.toml pyproject.toml
# Install from requirements file
RUN uv pip install -r pyproject.toml




RUN uv pip install aws-opentelemetry-distro==0.12.2


# Signal that this is running in Docker for host binding logic
ENV DOCKER_CONTAINER=1

# Create non-root user
RUN useradd -m -u 1000 bedrock_agentcore
USER bedrock_agentcore

EXPOSE 9000
EXPOSE 8000
EXPOSE 8080

# Copy entire project (respecting .dockerignore)
COPY . .

# Use the full module path

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',8080))==0 else 1)"

CMD ["opentelemetry-instrument", "python", "-m", "src.main"]
