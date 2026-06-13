# pmhc-md-agent — containerized GROMACS pMHC MD runner (local + Vast.ai/SkyPilot).
#
# Base: NVIDIA NGC GROMACS 2024.2 (tuned GPU build). Pulling it requires an NGC
# login at build time:   docker login nvcr.io   (username '$oauthtoken', NGC API key)
#
# Build:  docker build -t pmhc-md-agent .
# Run:    see README.md  (bind-mount the replica folder at /work)
FROM nvcr.io/hpc/gromacs:2024.2

ENV DEBIAN_FRONTEND=noninteractive
# Python (CLI) + SkyPilot/Vast/rsync/ssh (cloud orchestration). The NGC image is
# Ubuntu-based; gmx is provided by the base image and put on PATH by entrypoint.sh.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv rsync openssh-client ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m pip install --no-cache-dir --upgrade pip \
    && python3 -m pip install --no-cache-dir "skypilot[vast]" vastai

WORKDIR /opt/pmhc-md-agent
COPY mdagent/    ./mdagent/
COPY scripts/    ./scripts/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && find ./scripts -name '*.sh' -exec chmod +x {} + \
    && find ./scripts -name '*.py' -exec chmod +x {} +

ENV PYTHONPATH=/opt/pmhc-md-agent \
    PYTHONUNBUFFERED=1

# The replica folder is bind-mounted here at runtime.
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--help"]
