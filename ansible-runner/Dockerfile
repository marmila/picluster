FROM ghcr.io/helmfile/helmfile:v1.2.3 AS helmfile

FROM python:slim

# Match container user UID/GID with host user
ARG UID=1000
ARG GID=1000

ARG ANSIBLE_GALAXY_CLI_COLLECTION_OPTS=--ignore-certs
ARG ANSIBLE_GALAXY_CLI_ROLE_OPTS=--ignore-certs

RUN apt-get update -qq && \
    apt-get install sudo git apt-utils python3-pip pwgen gnupg curl -y && \
    apt-get clean && \
    rm -rf /usr/share/doc/* /usr/share/man/* /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install basic Python packages
RUN pip3 install --upgrade pip setuptools
# RUN pip3 install ansible-core ansible-runner

ADD build /build
WORKDIR /build

# Install python dependencies
RUN pip3 install -r requirements.txt

# Install ansible roles/collections dependencies
RUN ansible-galaxy role install $ANSIBLE_GALAXY_CLI_ROLE_OPTS -r requirements.yml --roles-path "/usr/share/ansible/roles" --timeout 600
RUN ANSIBLE_GALAXY_DISABLE_GPG_VERIFY=1 ansible-galaxy collection install $ANSIBLE_GALAXY_CLI_COLLECTION_OPTS -r requirements.yml --collections-path "/usr/share/ansible/collections"

# Configure ansible-runner
RUN ansible-playbook ansible_runner_setup.yml

# Copy helmfile
COPY --from=helmfile /usr/local/bin/helmfile /usr/local/bin/helmfile

# Create runner user with same UID/GID as host
RUN groupadd -g $GID runner && \
    useradd -u $UID -g $GID -m -d /home/runner -s /bin/bash runner && \
    echo runner 'ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

USER runner

# Install helmfile required plugins
RUN helm plugin install https://github.com/aslafy-z/helm-git
RUN helm plugin install https://github.com/databus23/helm-diff

# Fix GPG TTY for agent
RUN echo "export GPG_TTY=\$(tty)" >> /home/runner/.bashrc

WORKDIR /runner

