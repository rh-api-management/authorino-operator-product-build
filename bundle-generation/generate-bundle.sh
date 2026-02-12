#!/usr/bin/env bash
#
# Generate RHCL Authorino Operator bundle variants using yq
#
# This script takes the upstream Authorino operator bundle and transforms it
# into RHCL bundles for dev, stage, and prod environments.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
UPSTREAM_BUNDLE="${PROJECT_ROOT}/authorino-operator/bundle"
IMAGE_PULLSPECS="${PROJECT_ROOT}/image-pullspecs.yaml"
AUTHORINO_CONFIG="${SCRIPT_DIR}/authorino-operator.yaml"
ANNOTATIONS_FILE="${SCRIPT_DIR}/annotations.yaml"

# Check dependencies
if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed"
    echo "Install: https://github.com/mikefarah/yq#install"
    exit 1
fi

# Verify config files exist
if [[ ! -f "$AUTHORINO_CONFIG" ]]; then
    echo "Error: Authorino config not found at $AUTHORINO_CONFIG"
    exit 1
fi

if [[ ! -f "$IMAGE_PULLSPECS" ]]; then
    echo "Error: Image pullspecs not found at $IMAGE_PULLSPECS"
    exit 1
fi

echo "========================================"
echo "Loading configuration from:"
echo "  Config:      $AUTHORINO_CONFIG"
echo "  Pullspecs:   $IMAGE_PULLSPECS"
echo "========================================"

# Read image pullspecs
OPERATOR_IMAGE=$(yq '.images.operator' "$IMAGE_PULLSPECS")
AUTHORINO_IMAGE=$(yq '.images.authorino' "$IMAGE_PULLSPECS")

echo ""
echo "Image pullspecs:"
echo "  operator:   $OPERATOR_IMAGE"
echo "  authorino:  $AUTHORINO_IMAGE"

# Extract SHAs from the quay.io images
OPERATOR_SHA="${OPERATOR_IMAGE##*@}"
AUTHORINO_SHA="${AUTHORINO_IMAGE##*@}"

# Read Authorino configuration values
CSV_NAME=$(yq '.csv.name' "$AUTHORINO_CONFIG")
CSV_VERSION=$(yq '.csv.version' "$AUTHORINO_CONFIG")
DISPLAY_NAME=$(yq '.csv.displayName' "$AUTHORINO_CONFIG")
DESCRIPTION=$(yq '.csv.description' "$AUTHORINO_CONFIG")
DOC_URL=$(yq '.links.documentation' "$AUTHORINO_CONFIG")
REPO_URL=$(yq '.links.repository' "$AUTHORINO_CONFIG")
VALID_SUBSCRIPTION=$(yq '.validSubscription' "$AUTHORINO_CONFIG")

# Check if icon is configured
ICON_BASE64=$(yq '.csv.icon[0].base64data // ""' "$AUTHORINO_CONFIG")
ICON_MEDIATYPE=$(yq '.csv.icon[0].mediatype // ""' "$AUTHORINO_CONFIG")

echo ""
echo "Authorino configuration:"
echo "  CSV name:     $CSV_NAME"
echo "  Version:      $CSV_VERSION"
echo "  Display name: $DISPLAY_NAME"

# Build registry mappings for each environment
get_operator_image() {
    local env=$1
    if [[ "$env" == "dev" ]]; then
        echo "$OPERATOR_IMAGE"
    else
        local registry=$(yq ".registries.${env}.operator" "$AUTHORINO_CONFIG")
        echo "${registry}@${OPERATOR_SHA}"
    fi
}

get_authorino_image() {
    local env=$1
    if [[ "$env" == "dev" ]]; then
        echo "$AUTHORINO_IMAGE"
    else
        local registry=$(yq ".registries.${env}.authorino" "$AUTHORINO_CONFIG")
        echo "${registry}@${AUTHORINO_SHA}"
    fi
}

# Generate bundle for each environment
for env in dev stage prod; do
    output_dir="${PROJECT_ROOT}/$(yq ".outputDirs.${env}" "$AUTHORINO_CONFIG")"
    manifests_dir="${output_dir}/manifests"
    metadata_dir="${output_dir}/metadata"

    echo ""
    echo "========================================"
    echo "Generating ${env} bundle"
    echo "Output: ${output_dir}"
    echo "========================================"

    # Clean and create output directories
    rm -rf "${output_dir}"
    mkdir -p "${manifests_dir}" "${metadata_dir}"

    # Copy all manifests from upstream
    cp "${UPSTREAM_BUNDLE}/manifests/"*.yaml "${manifests_dir}/"
    # Use downstream annotations (with RHCL-specific values)
    cp "${ANNOTATIONS_FILE}" "${metadata_dir}/"

    CSV_FILE="${manifests_dir}/authorino-operator.clusterserviceversion.yaml"

    # Get the image references for this environment
    operator_image=$(get_operator_image "$env")
    authorino_image=$(get_authorino_image "$env")

    echo "  Operator:   ${operator_image}"
    echo "  Authorino:  ${authorino_image}"

    # Update CSV: operator container image
    yq -i '(.spec.install.spec.deployments[] | select(.name == "authorino-operator") | .spec.template.spec.containers[] | select(.name == "manager") | .image) = "'"${operator_image}"'"' "${CSV_FILE}"

    # Update CSV: containerImage annotation
    yq -i '.metadata.annotations.containerImage = "'"${operator_image}"'"' "${CSV_FILE}"

    # Update CSV: authorino in RELATED_IMAGE_AUTHORINO env var
    yq -i '(.spec.install.spec.deployments[] | select(.name == "authorino-operator") | .spec.template.spec.containers[] | select(.name == "manager") | .env[] | select(.name == "RELATED_IMAGE_AUTHORINO") | .value) = "'"${authorino_image}"'"' "${CSV_FILE}"

    # Update CSV: authorino in relatedImages
    yq -i '(.spec.relatedImages[] | select(.name == "authorino") | .image) = "'"${authorino_image}"'"' "${CSV_FILE}"

    # Update CSV: Add RHCL-specific feature annotations from config
    yq -i '.metadata.annotations["features.operators.openshift.io/disconnected"] = "'"$(yq '.features.disconnected' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/fips-compliant"] = "'"$(yq '.features.fips-compliant' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/proxy-aware"] = "'"$(yq '.features.proxy-aware' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/tls-profiles"] = "'"$(yq '.features.tls-profiles' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/token-auth-aws"] = "'"$(yq '.features.token-auth-aws' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/token-auth-azure"] = "'"$(yq '.features.token-auth-azure' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/token-auth-gcp"] = "'"$(yq '.features.token-auth-gcp' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/cnf"] = "'"$(yq '.features.cnf' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/cni"] = "'"$(yq '.features.cni' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/csi"] = "'"$(yq '.features.csi' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"

    # Update CSV: valid subscription
    yq -i '.metadata.annotations["operators.openshift.io/valid-subscription"] = "[\"'"${VALID_SUBSCRIPTION}"'\"]"' "${CSV_FILE}"

    # Update CSV: Add architecture labels from config
    yq -i '.metadata.labels["operatorframework.io/os.linux"] = "'"$(yq '.architectures."os.linux"' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.labels["operatorframework.io/arch.amd64"] = "'"$(yq '.architectures.amd64' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.labels["operatorframework.io/arch.arm64"] = "'"$(yq '.architectures.arm64' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.labels["operatorframework.io/arch.ppc64le"] = "'"$(yq '.architectures.ppc64le' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.labels["operatorframework.io/arch.s390x"] = "'"$(yq '.architectures.s390x' "$AUTHORINO_CONFIG")"'"' "${CSV_FILE}"

    # Update CSV: Set display name and description
    yq -i ".metadata.name = \"${CSV_NAME}\"" "${CSV_FILE}"
    yq -i ".spec.version = \"${CSV_VERSION}\"" "${CSV_FILE}"
    yq -i ".spec.displayName = \"${DISPLAY_NAME}\"" "${CSV_FILE}"
    yq -i ".spec.description = \"${DESCRIPTION}\"" "${CSV_FILE}"

    # Update CSV: Set icon if configured
    if [[ -n "$ICON_BASE64" && -n "$ICON_MEDIATYPE" ]]; then
        yq -i ".spec.icon[0].base64data = \"${ICON_BASE64}\"" "${CSV_FILE}"
        yq -i ".spec.icon[0].mediatype = \"${ICON_MEDIATYPE}\"" "${CSV_FILE}"
    fi

    # Update CSV: Set documentation and repository links
    yq -i '.metadata.annotations.repository = "'"${REPO_URL}"'"' "${CSV_FILE}"
    yq -i '(.spec.links[] | select(.name == "Authorino Operator") | .url) = "'"${DOC_URL}"'"' "${CSV_FILE}"

    # Update CSV: Remove replaces and skipRange (managed in catalog repo)
    yq -i 'del(.spec.replaces)' "${CSV_FILE}"
    yq -i 'del(.spec.skipRange)' "${CSV_FILE}"

    echo "  Done!"
done

echo ""
echo "========================================"
echo "All bundles generated successfully!"
echo "========================================"
echo ""
echo "Output directories:"
echo "  - bundle/       (production)"
echo "  - bundle-dev/   (development)"
echo "  - bundle-stage/ (staging)"
echo ""
