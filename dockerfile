FROM ubuntu:24.04
# FROM alpine:3.20
ARG USERNAME=user
# TODO: pin versions

# NOTE: below is for ubuntu:24.04 — shadow-utils ships useradd by default there,
# so -m works as-is; no extra package needed.

RUN apt-get update && \
  apt-get install -y --no-install-recommends openssh-server ca-certificates && \
  rm -rf /var/lib/apt/lists/*


RUN useradd -m -s /bin/bash "${USERNAME}" && \
  mkdir -p /home/${USERNAME}/.ssh && \
  chmod 700 /home/${USERNAME}/.ssh

# ensure password not required - pubkey auth still used
RUN passwd -u "${USERNAME}"  


# # Install minimal SSH server + tools (ALPINE)
# RUN apk add --no-cache openssh bash
#
# Create user and SSH dir (BusyBox adduser: -D = no password, skip prompts;
# also creates the home dir, so no separate mkdir needed for it)
# RUN adduser -D -s /bin/bash "${USERNAME}" && \
#   mkdir -p /home/${USERNAME}/.ssh && \
#   chmod 700 /home/${USERNAME}/.ssh

# Harden sshd config a bit
RUN sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
  sed -i 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config && \
  sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
  echo "PermitRootLogin no" >> /etc/ssh/sshd_config

# Create host keys
RUN ssh-keygen -A

# Ensure correct perms at runtime (authorized_keys will be mounted)
RUN chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh && \
  chmod 700 /home/${USERNAME}/.ssh


# open port and run ssh server daemon on start
EXPOSE 22
CMD ["/usr/sbin/sshd","-D","-e"]
