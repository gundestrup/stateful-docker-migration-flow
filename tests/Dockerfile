# Mocked regression image; no live Docker daemon or NAS is touched.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends bash jq && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
CMD ["bash", "tests/run.sh"]
