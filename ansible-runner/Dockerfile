FROM ghcr.io/helmfile/helmfile:v1.3.2 AS helmfile

FROM python:slim

ARG ANSIBLE_GALAXY_CLI_COLLECTION_OPTS=--ignore-certs
ARG ANSIBLE_GALAXY_CLI_ROLE_OPTS=--ignore-certs

RUN apt-get update -qq && \
    apt-get install -y sudo git apt-utils python3-pip pwgen gnupg curl && \
    apt-get clean && \
    rm -rf /usr/share/doc/* /usr/share/man/* /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN pip3 install --upgrade pip setuptools
RUN pip3 install ansible-core ansible-runner certbot

ADD build /build
WORKDIR /build

RUN pip3 install -r requirements.txt

RUN ansible-galaxy role install $ANSIBLE_GALAXY_CLI_ROLE_OPTS -r requirements.yml --roles-path "/usr/share/ansible/roles"
RUN ANSIBLE_GALAXY_DISABLE_GPG_VERIFY=1 ansible-galaxy collection install $ANSIBLE_GALAXY_CLI_COLLECTION_OPTS -r requirements.yml --collections-path "/usr/share/ansible/collections"

RUN ansible-playbook ansible_runner_setup.yml

COPY --from=helmfile /usr/local/bin/helmfile /usr/local/bin/helmfile

ENV USER runner
ENV FOLDER /home/runner
RUN /usr/sbin/groupadd $USER && \
    /usr/sbin/useradd $USER -m -d $FOLDER -g $USER -s /bin/bash && \
    echo "$USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

RUN mkdir -p /runner \
             /runner/.vault \
             /runner/.gnupg \
             /runner/.secrets \
             /var/lib/letsencrypt \
             /etc/letsencrypt \
             /var/log/letsencrypt && \
    chown -R $USER:$USER /runner /runner/.vault /runner/.gnupg /runner/.secrets \
             /var/lib/letsencrypt /etc/letsencrypt /var/log/letsencrypt && \
    chmod -R 775 /runner /runner/.vault /runner/.gnupg /runner/.secrets \
             /var/lib/letsencrypt /etc/letsencrypt /var/log/letsencrypt

USER $USER

RUN helm plugin install https://github.com/aslafy-z/helm-git
RUN helm plugin install https://github.com/databus23/helm-diff

RUN echo "export GPG_TTY=\$(tty)" >> /home/runner/.bashrc

WORKDIR /runner
