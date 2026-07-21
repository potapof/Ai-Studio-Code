# Patched OpenHands runtime: fix missing micromamba binary
# The code expects /openhands/micromamba/bin/micromamba
# but the image has miniforge3 with conda/mamba
FROM ghcr.io/all-hands-ai/runtime:main
RUN mkdir -p /openhands/micromamba/bin && \
    ln -s /openhands/miniforge3/condabin/mamba /openhands/micromamba/bin/micromamba && \
    echo "micromamba symlink created: $(ls -la /openhands/micromamba/bin/micromamba)"
