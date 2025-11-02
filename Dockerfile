# Minimal Dockerfile for Hunt v2 Production (Author: JFlow)
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    python3 python3-pip nodejs npm curl jq git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy application
COPY . /app

# Install Python deps
RUN pip3 install --no-cache requests beautifulsoup4

# Install puppeteer dependencies & node modules
WORKDIR /app/tools
RUN npm init -y || true
RUN npm install puppeteer --no-audit --silent

WORKDIR /app
RUN chmod +x ./hunt_v2_production.sh
ENTRYPOINT ["/app/hunt_v2_production.sh"]
