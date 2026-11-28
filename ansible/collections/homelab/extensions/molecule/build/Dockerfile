# Shared test image for every molecule scenario: openSUSE Tumbleweed with systemd
# as PID 1, sshd and sudo. Built once per run, referenced by each scenario's
# molecule.yml as `homelab-molecule:tumbleweed`.
#   docker build -t homelab-molecule:tumbleweed collections/homelab/extensions/molecule/build
FROM registry.opensuse.org/opensuse/tumbleweed:latest

RUN zypper --non-interactive install --no-recommends \
        systemd sudo python3 shadow iproute2 openssh dbus-1 NetworkManager diffutils && \
    zypper clean --all && \
    ssh-keygen -A && \
    mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sf /usr/lib/systemd/system/dbus-broker.service /etc/systemd/system/dbus.service && \
    ln -sf /usr/lib/systemd/system/dbus-broker.service /etc/systemd/system/multi-user.target.wants/dbus-broker.service && \
    ln -sf /usr/lib/systemd/system/NetworkManager.service /etc/systemd/system/multi-user.target.wants/NetworkManager.service

STOPSIGNAL SIGRTMIN+3
CMD ["/usr/lib/systemd/systemd"]
