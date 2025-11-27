#!/usr/bin/env bash

# enables strict mode: `-e` fails if error, `-u` checks variable references, `-o pipefail`: prevents errors in a pipeline from being masked
set -euo pipefail

# Load Authorino Operator configuration from properties file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/authorino-operator.properties"

export CSV_FILE=/manifests/authorino-operator.clusterserviceversion.yaml
export IMAGE_PULLSPECS_FILE=${IMAGE_PULLSPECS_FILE:-${SCRIPT_DIR}/image-pullspecs.yaml}

# Production registry pullspecs
export AUTHORINO_OPERATOR_IMAGE_PULLSPEC="registry.redhat.io/rhcl-1/authorino-rhel9-operator"
export AUTHORINO_IMAGE_PULLSPEC="registry.redhat.io/rhcl-1/authorino-rhel9"

# Stage registry pullspecs
export AUTHORINO_OPERATOR_IMAGE_PULLSPEC_STAGE="registry.stage.redhat.io/rhcl-1/authorino-rhel9-operator"
export AUTHORINO_IMAGE_PULLSPEC_STAGE="registry.stage.redhat.io/rhcl-1/authorino-rhel9"

# Load description and icon
export DESCRIPTION=$(cat "${SCRIPT_DIR}/DESCRIPTION")
export ICON=$(cat "${SCRIPT_DIR}/ICON")

echo "Loading image pullspecs from ${IMAGE_PULLSPECS_FILE}..."
export EPOC_TIMESTAMP=$(date +%s)

# Python script to update CSV
python3 - << CSV_UPDATE
import os
from sys import exit as sys_exit
from datetime import datetime
from ruamel.yaml import YAML

yaml = YAML()

def load_manifest(pathn):
   if not pathn.endswith(".yaml"):
      return None
   try:
      with open(pathn, "r") as f:
         return yaml.load(f)
   except FileNotFoundError:
      print(f"File {pathn} not found")
      exit(2)

def dump_manifest(pathn, manifest):
   with open(pathn, "w") as f:
      yaml.dump(manifest, f)
   return

def update_or_append_to_env(l, name, value):
   obj = None
   for x in l:
      if x["name"] == name:
         obj = x
         break
   if not obj:
      obj = { "name": name }
      l.append(obj)
   obj["value"] = value

# Load image pullspecs from YAML file
image_pullspecs_file = os.getenv('IMAGE_PULLSPECS_FILE')
print(f"Reading image pullspecs from: {image_pullspecs_file}")
image_pullspecs = load_manifest(image_pullspecs_file)

if not image_pullspecs or 'images' not in image_pullspecs:
   print("Error: Invalid image pullspecs file")
   exit(1)

images = image_pullspecs['images']
operator_image = images.get('operator', '')
authorino_image = images.get('authorino', '')

print(f"Operator image from pullspecs: {operator_image}")
print(f"Authorino image from pullspecs: {authorino_image}")

# Determine target registry based on environment
development = os.getenv('development', '').lower() == 'true'
stage = os.getenv('stage', '').lower() == 'true'

if development:
   print("Development bundle: using Quay.io pullspecs")
   target_operator_image = operator_image
   target_authorino_image = authorino_image
elif stage:
   print("Stage bundle: using staging registry pullspecs")
   target_operator_image = os.getenv('AUTHORINO_OPERATOR_IMAGE_PULLSPEC_STAGE')
   target_authorino_image = os.getenv('AUTHORINO_IMAGE_PULLSPEC_STAGE')
else:
   print("Production bundle: using production registry pullspecs")
   target_operator_image = os.getenv('AUTHORINO_OPERATOR_IMAGE_PULLSPEC')
   target_authorino_image = os.getenv('AUTHORINO_IMAGE_PULLSPEC')

# Load configuration from properties
csv_name = os.getenv('NAME')
csv_version = os.getenv('CSV_VERSION')
display_name = os.getenv('DISPLAY_NAME')
description = os.getenv('DESCRIPTION')
icon = os.getenv('ICON')
channel = os.getenv('CHANNEL', 'stable')
valid_subscription = os.getenv('VALID_SUBSCRIPTION')

# Load and update CSV
timestamp = int(os.getenv('EPOC_TIMESTAMP'))
datetime_time = datetime.fromtimestamp(timestamp)

print(f"Updating CSV to version: {csv_version}, name: {csv_name}")
authorino_operator_csv = load_manifest(os.getenv('CSV_FILE'))

# Update CSV metadata name
authorino_operator_csv['metadata']['name'] = csv_name

# Update spec.version
authorino_operator_csv['spec']['version'] = csv_version

# Update spec.displayName
authorino_operator_csv['spec']['displayName'] = display_name

# Update spec.description
authorino_operator_csv['spec']['description'] = description

# Remove replaces/skipRange - upgrade path is managed in file-based catalog
if 'replaces' in authorino_operator_csv['spec']:
   del authorino_operator_csv['spec']['replaces']
   print("Removed replaces field (managed in catalog)")
if 'skipRange' in authorino_operator_csv['spec']:
   del authorino_operator_csv['spec']['skipRange']
   print("Removed skipRange field (managed in catalog)")

# Replace operator image references
# 1. In metadata.annotations.containerImage
if 'containerImage' in authorino_operator_csv['metadata']['annotations']:
   old_image = authorino_operator_csv['metadata']['annotations']['containerImage']
   authorino_operator_csv['metadata']['annotations']['containerImage'] = target_operator_image
   print(f"Updated containerImage: {old_image} -> {target_operator_image}")

# 2. In spec.install.spec.deployments[0].spec.template.spec.containers[0].image
try:
   deployment = authorino_operator_csv['spec']['install']['spec']['deployments'][0]
   container = deployment['spec']['template']['spec']['containers'][0]
   old_image = container['image']
   container['image'] = target_operator_image
   print(f"Updated container image: {old_image} -> {target_operator_image}")
except (KeyError, IndexError) as e:
   print(f"Warning: Could not update deployment container image: {e}")

# 3. Update authorino operand image in relatedImages
if 'relatedImages' in authorino_operator_csv['spec']:
   for img in authorino_operator_csv['spec']['relatedImages']:
      img_name = img.get('name', '')
      img_url = img.get('image', '')
      # Look for authorino (not authorino-operator) in relatedImages
      if 'authorino' in img_name and 'operator' not in img_name:
         old_image = img['image']
         img['image'] = target_authorino_image
         print(f"Updated authorino operand image: {old_image} -> {target_authorino_image}")
         break

# 4. Update authorino operand image in deployment environment variables
try:
   deployment = authorino_operator_csv['spec']['install']['spec']['deployments'][0]
   container = deployment['spec']['template']['spec']['containers'][0]
   if 'env' in container:
      for env in container['env']:
         if env.get('name') == 'RELATED_IMAGE_AUTHORINO':
            old_image = env.get('value', '')
            env['value'] = target_authorino_image
            print(f"Updated RELATED_IMAGE_AUTHORINO env var: {old_image} -> {target_authorino_image}")
            break
except (KeyError, IndexError) as e:
   print(f"Warning: Could not update authorino env var: {e}")

# Add arch and os support labels
authorino_operator_csv['metadata']['labels'] = authorino_operator_csv['metadata'].get('labels', {})
authorino_operator_csv['metadata']['labels']['operatorframework.io/os.linux'] = 'supported'

# Ensure that the created timestamp is current
authorino_operator_csv['metadata']['annotations']['createdAt'] = datetime_time.strftime('%d %b %Y, %H:%M')

# Add annotations for the openshift operator features
authorino_operator_csv['metadata']['annotations']['features.operators.openshift.io/disconnected'] = 'true'
authorino_operator_csv['metadata']['annotations']['features.operators.openshift.io/fips-compliant'] = 'false'
authorino_operator_csv['metadata']['annotations']['features.operators.openshift.io/proxy-aware'] = 'false'
authorino_operator_csv['metadata']['annotations']['features.operators.openshift.io/tls-profiles'] = 'false'
authorino_operator_csv['metadata']['annotations']['features.operators.openshift.io/token-auth-aws'] = 'false'
authorino_operator_csv['metadata']['annotations']['features.operators.openshift.io/token-auth-azure'] = 'false'
authorino_operator_csv['metadata']['annotations']['features.operators.openshift.io/token-auth-gcp'] = 'false'
authorino_operator_csv['metadata']['annotations']['features.operators.openshift.io/cnf'] = 'false'
authorino_operator_csv['metadata']['annotations']['features.operators.openshift.io/cni'] = 'false'
authorino_operator_csv['metadata']['annotations']['features.operators.openshift.io/csi'] = 'false'
authorino_operator_csv['metadata']['annotations']['operators.openshift.io/valid-subscription'] = valid_subscription
authorino_operator_csv['metadata']['annotations']['repository'] = 'https://github.com/kuadrant/authorino-operator'

# Add icon
authorino_operator_csv['spec']['icon'][0]['base64data'] = icon

# Save updated CSV
dump_manifest(os.getenv('CSV_FILE'), authorino_operator_csv)
print(f"Successfully updated CSV: {os.getenv('CSV_FILE')}")

CSV_UPDATE

echo "CSV update complete"
cat $CSV_FILE
