#!/bin/sh

set -e # Exit on any error
set -u # Treat unset variables as an error

# Define paths
MIXINS_DIR="./templates"

# Clean the templates directory
echo "Cleaning templates directory..."
rm -rf ${MIXINS_DIR}/*
echo "Templates directory cleaned."

# Convert Jsonnet to YAML
echo "Converting Jsonnet to YAML..."
jsonnet main.jsonnet -J vendor -m ${MIXINS_DIR} | xargs -I{} sh -c 'cat {} | gojsontoyaml > {}.yaml' -- {}
echo "Jsonnet conversion completed."

# Remove all non-YAML files
echo "Removing non-YAML files..."
find ${MIXINS_DIR} -type f ! -name "*.yaml" -exec rm {} +
echo "Non-YAML files removed."

# No Helm-style {{`{{`}} escaping: these rule files are applied by Flux/Kustomize,
# not rendered by Helm, so escaping would reach Alertmanager as literal text
# and alerts would show "{{ $labels.pod }}" instead of the pod name.

echo "Processing completed successfully!"
