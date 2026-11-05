# All packages below are installed INSIDE this disposable harness, never on the host.
FROM debian:12@sha256:268fb24c39bca92d326dd83ea3abebe4a3f7751c804ffef23bb6d857dd343ff8
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-x86 qemu-utils cloud-image-utils openssh-client ca-certificates curl python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /harness
COPY guest.sh /harness/guest.sh
COPY boot.sh /harness/boot.sh
ENTRYPOINT ["bash", "/harness/boot.sh"]
