# gmx-md-agent — containerized GROMACS MD runner (local + Vast.ai/SkyPilot).
#
# GROMACS 2024.2 (CUDA) is installed from conda-forge — NO registry login is
# required to build (the CUDA base is public on Docker Hub). This matches the
# version the Vast nodes install and your on-prem standard, so `extend` can read
# existing 2024.2 .tpr files.
#
# Build:  make build   (docker build -t gmx-md-agent .)
# Run:    see README.md  (bind-mount the run folder at /work; ./mda wrapper)
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl bzip2 git rsync openssh-client \
    && rm -rf /var/lib/apt/lists/*

# micromamba -> GROMACS 2024.2 (CUDA) + python + pip in /opt/gmx; then the
# cloud-orchestration python deps into that same env.
ENV MAMBA_ROOT_PREFIX=/opt/micromamba GMXENV=/opt/gmx
RUN curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest \
      | tar -xj -C /usr/local/bin --strip-components=1 bin/micromamba
RUN micromamba create -y -p "$GMXENV" -c conda-forge \
        "gromacs=2024.2=nompi_cuda_*" python=3.11 pip \
    || micromamba create -y -p "$GMXENV" -c conda-forge \
        "gromacs=2024.2" python=3.11 pip
RUN "$GMXENV/bin/pip" install --no-cache-dir --upgrade pip \
    && "$GMXENV/bin/pip" install --no-cache-dir "skypilot[vast]" vastai
ENV PATH=/opt/gmx/bin:$PATH

WORKDIR /opt/gmx-md-agent
COPY mdagent/    ./mdagent/
COPY scripts/    ./scripts/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && find ./scripts -name '*.sh' -exec chmod +x {} + \
    && find ./scripts -name '*.py' -exec chmod +x {} +

# Patch SkyPilot's Vast provisioner: it builds a search query with geolocation,
# which makes Vast IGNORE the gpu_name filter and return all GPU types; it then
# takes instance_list[0] — often a Blackwell card (RTX 5090 / B200) that the
# GROMACS 2024.2 CUDA-11.8 build cannot run. The patch strictly keeps the exact
# requested GPU (cheapest, optional VAST_MAX_DPH ceiling) so it never substitutes.
RUN python3 ./scripts/cloud/patches/patch_sky_vast.py

ENV PYTHONPATH=/opt/gmx-md-agent \
    PYTHONUNBUFFERED=1

# The run folder is bind-mounted here at runtime.
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--help"]
