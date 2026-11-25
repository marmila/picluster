.PHONY: default create-local-directories start-ansible-runner
LOCAL_DIRS := ${HOME}/.ansible ${HOME}/.ansible/collections ${HOME}/.ansible/roles ${HOME}/.secrets ${HOME}/.ssh ${HOME}/.kube ${HOME}/.certbot/logs ${HOME}/.certbot/config ${HOME}/.certbot/work

default: start-ansible-runner

create-local-directories:
	mkdir -p ${LOCAL_DIRS}

${HOME}/.ssh/id_rsa:
	ssh-keygen -t rsa -P '' -f ${HOME}/.ssh/id_rsa

start-ansible-runner: create-local-directories ${HOME}/.ssh/id_rsa
	# --build: rebuild the image when the Dockerfile or ansible/pyproject.toml changed (Renovate bumps);
	# without it a running container kept the old image (2026-11-25). Cached, so quick when nothing changed.
	docker compose up --detach --build