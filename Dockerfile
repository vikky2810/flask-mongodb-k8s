FROM python:3.10-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Dependencies first so this layer is cached when only app code changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as an unprivileged user
RUN useradd --uid 10001 --no-create-home appuser
USER 10001

EXPOSE 5000

# gunicorn instead of the Flask dev server: multi-worker, production-grade
# Shell form so ${PORT} expands: Render injects PORT, Kubernetes/local default to 5000
CMD gunicorn --bind 0.0.0.0:${PORT:-5000} --workers 2 --threads 2 --access-logfile - app:app
