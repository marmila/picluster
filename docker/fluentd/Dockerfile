# Upstream aggregator image (fluentd 1.20.1, amd64 + arm64), plus the Kafka output for threatmap.
FROM ghcr.io/ricsanfre/fluentd-aggregator:v1.20.1-debian-1.1
USER root
RUN fluent-gem install fluent-plugin-kafka --no-document
USER 1000
