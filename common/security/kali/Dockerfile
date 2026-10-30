# Kali Linux toolbox for testing systems you own or are authorized to test. Built on demand by common/kali (`kali`).
# Base: the official Kali image. It only has the rolling tag `latest` (no dated tags): `kali update` rebuilds on the newest.
# Override with --build-arg KALI_IMAGE=kalilinux/kali-rolling@sha256:<digest> to pin a digest.
ARG KALI_IMAGE=kalilinux/kali-rolling:latest
FROM ${KALI_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# kali-linux-headless: the command-line tools (nmap, nikto, sqlmap, hydra, ...). Several GB.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends kali-linux-headless sudo ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Non-root default user; sudo inside the container for the tools that need raw sockets (nmap -sS). No password, no keys.
RUN useradd --create-home --shell /bin/bash --uid 1000 kali \
 && echo 'kali ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/kali \
 && chmod 0440 /etc/sudoers.d/kali

USER kali
WORKDIR /home/kali
CMD ["/bin/bash"]
