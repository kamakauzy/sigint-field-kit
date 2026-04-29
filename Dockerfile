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

COPY install.sh /home/sigint/install.sh
COPY verify-setup.sh /home/sigint/verify-setup.sh
COPY uninstall.sh /home/sigint/uninstall.sh
RUN chmod +x /home/sigint/*.sh && chown sigint:sigint /home/sigint/*.sh

# Run the installer (rx-only mode, skip graphical apps that need a display)
RUN /home/sigint/install.sh --rx-only --skip-update 2>&1 || true

USER sigint
WORKDIR /home/sigint

CMD ["bash"]
