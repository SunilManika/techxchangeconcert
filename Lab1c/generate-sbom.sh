#!/bin/bash

set -euo pipefail

IMAGES=(
  "docker.io/sunilmanika/retail-postgresql:1.0.0"
  "docker.io/sunilmanika/retail-frontend:1.0.0"
  "docker.io/sunilmanika/retail-jmeter:1.0.1"
  "docker.io/sunilmanika/retail-backend:1.0.0"
)

for IMAGE in "${IMAGES[@]}"; do

    IMAGE_NAME=$(basename "$IMAGE" | cut -d':' -f1)

    TMP="${IMAGE_NAME}.tmp.cdx.json"
    OUTPUT="${IMAGE_NAME}.cdx.json"

    echo "=================================================="
    echo "Scanning image: $IMAGE"
    echo "=================================================="

    trivy image \
      --scanners vuln \
      --format cyclonedx \
      --output "$TMP" \
      "$IMAGE"

    echo "Trivy CycloneDX version:"
    jq -r '.specVersion' "$TMP"

    echo "Vulnerabilities detected:"
    jq '.vulnerabilities | length // 0' "$TMP"

    # Convert CycloneDX 1.7 -> 1.6 for Concert
    cyclonedx convert \
      --input-file "$TMP" \
      --output-file "$OUTPUT" \
      --output-version v1_6

    rm -f "$TMP"

    echo "Final CycloneDX version:"
    jq -r '.specVersion' "$OUTPUT"

    echo "Vulnerabilities in final file:"
    jq '.vulnerabilities | length // 0' "$OUTPUT"

    echo "Generated: $OUTPUT"
    echo

done

echo "=================================================="
echo "Completed"
echo "=================================================="

ls -lh *.cdx.json