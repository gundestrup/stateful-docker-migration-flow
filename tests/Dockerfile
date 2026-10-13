# Mocked regression image; no live Docker daemon or NAS is touched.
# kcov collects Bash line coverage when the suite is run through it (see
# .github/workflows/ci.yml); the default CMD runs uninstrumented.
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends bash jq kcov && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
CMD ["bash", "tests/run.sh"]
