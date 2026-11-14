FROM ubuntu:22.04

LABEL maintainer="sigint-field-kit"
LABEL description="Test environment for sigint-field-kit installer"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Minimal base to simulate DragonOS (Ubuntu 22.04 base)
RUN apt-get update && apt-get install -y --no-install-recommends \
    sudo \
    bash \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user to simulate real usage
RUN useradd -m -s /bin/bash sigint && \
    echo "sigint ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

COPY install.sh verify-setup.sh uninstall.sh /home/sigint/
COPY scripts/ /home/sigint/scripts/
COPY tools/ /home/sigint/tools/
# Strip CRLF in case the build context was checked out on Windows (autocrlf)
RUN mkdir -p /home/sigint/data \
    && find /home/sigint -type f \( -name '*.sh' -o -name '*.py' \) -exec sed -i 's/\r$//' {} + \
    && chmod +x /home/sigint/*.sh && chown -R sigint:sigint /home/sigint

# --skip-update skips apt-get update, so refresh the package lists here
RUN apt-get update

# Run the installer (rx-only mode). Fails the build if install.sh fails;
# optional components that cannot install in a container WARN instead.
# $USER is unset in RUN steps, install.sh falls back to root.
RUN /home/sigint/install.sh --rx-only --skip-update \
    && test -f /home/sigint/data/freq_db.sqlite

USER sigint
WORKDIR /home/sigint

CMD ["bash"]
