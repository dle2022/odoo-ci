# Optional custom image if your addons need extra deps
ARG ODOO_VERSION=18.0
FROM odoo:${ODOO_VERSION}

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libpq-dev \
  && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/requirements.txt || true

USER odoo
