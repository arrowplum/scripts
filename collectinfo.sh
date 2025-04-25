#!/bin/bash
# Add line numbers to debug output by modifying PS4
export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR
handle_error() {
  local lineno=$1
  echo "❌ Script exited with error at line $lineno"
  exit 1
}

set -euo pipefail
if [ "${DEBUG:-false}" = true ]; then
    set -x
fi


# Configuration
NAMESPACE="avs"
INIT_CONTAINER="config-injector"
CONFIG_PATH="/etc/aerospike-vector-search/aerospike-vector-search.yml"
OUTPUT_DIR="./avs-inspection-output"
TMP_FILE="avs-full-context.txt"
MARKDOWN_REPORT="$OUTPUT_DIR/analysis.md"
TEXT_SUMMARY="$OUTPUT_DIR/summary-report.txt"
MODEL="gpt-4o"
# Ensure OpenAI CLI is installed
command -v openai >/dev/null 2>&1 || {
  echo >&2 "❌ OpenAI CLI not found. Install with: pip install openai"; exit 1;
}

# Ensure output directory is clean
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "📦 Collecting diagnostics from namespace: $NAMESPACE"
echo "" > "$TMP_FILE"

# Function to process and summarize GC histogram
process_gc_histogram() {
    local input_file="$1"
    local output_file="$2"
    cat "$input_file"
    
    {
        echo "=== GC Histogram Summary ==="
        echo "Top $TOP_CLASSES memory-consuming classes:"
        # Skip header (first 3 lines), then take top N entries
        tail -n +4 "$input_file" | head -n $TOP_CLASSES
        
        echo -e "\n=== Memory Usage Statistics ==="
        # Calculate total instances and bytes from the full histogram
        tail -n +4 "$input_file" | awk '
            BEGIN { total_instances=0; total_bytes=0 }
            { 
                total_instances += $2; 
                total_bytes += $3;
            }
            END { 
                printf "Total Instances: %d\nTotal Bytes: %d\nAverage Bytes per Instance: %.2f\n", 
                    total_instances, total_bytes, (total_bytes/total_instances)
            }'
    } > "$output_file"
}
  # collect_pod_info: Collects diagnostic information for a Kubernetes pod
  # Arguments:
  #   $1 - pod name: The name of the pod to collect information from
collect_pod_info() {
    local pod="$1"
    echo "🔍 Inspecting pod: $pod"
    POD_DIR="$OUTPUT_DIR/$pod"
    echo "POD_DIR: $POD_DIR"
    mkdir -p "$POD_DIR"

    # Get the node name for this pod
    NODE_NAME=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.nodeName}')
    NODE_DIR="$OUTPUT_DIR/nodes/$NODE_NAME"
    mkdir -p "$NODE_DIR"

    # Collect node information if not already collected
    if [ ! -f "$NODE_DIR/node-info.txt" ]; then
      echo "📊 Collecting node information for: $NODE_NAME"
      {
        echo "=== Node Description ==="
        kubectl describe node "$NODE_NAME"
        echo -e "\n=== Node Resources ==="
        kubectl get node "$NODE_NAME" -o json | jq '.status.capacity'
        echo -e "\n=== Node Allocatable Resources ==="
        kubectl get node "$NODE_NAME" -o json | jq '.status.allocatable'
        echo -e "\n=== Node Conditions ==="
        kubectl get node "$NODE_NAME" -o json | jq '.status.conditions'
        
        echo -e "\n=== Cloud Instance Information ==="
        # AWS
        INSTANCE_TYPE=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
        if [ -n "$INSTANCE_TYPE" ]; then
          echo "Cloud Provider: AWS"
          echo "Instance Type: $INSTANCE_TYPE"
          echo "Region: $(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/region}')"
          echo "Zone: $(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
        fi
        
        # GCP
        INSTANCE_TYPE=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.cloud\.google\.com/gke-nodepool}')
        if [ -n "$INSTANCE_TYPE" ]; then
          echo "Cloud Provider: GCP"
          echo "Node Pool: $INSTANCE_TYPE"
          echo "Machine Type: $(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.cloud\.google\.com/machine-type}')"
          echo "Zone: $(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
        fi
        
        # Azure
        INSTANCE_TYPE=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
        if [ -n "$INSTANCE_TYPE" ] && [ -z "$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' | grep -i aws)" ]; then
          echo "Cloud Provider: Azure"
          echo "Instance Type: $INSTANCE_TYPE"
          echo "Region: $(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/region}')"
          echo "Zone: $(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
        fi
        
        # If no cloud provider detected
        if [ -z "$(grep 'Cloud Provider:' "$NODE_DIR/node-info.txt")" ]; then
          echo "Cloud Provider: Unknown or On-Premises"
          echo "Instance Type: $(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')"
        fi
      } > "$NODE_DIR/node-info.txt"
    fi
  }
  fi

  # 1. Config file
  kubectl exec -n "$NAMESPACE" "$pod" -- cat "$CONFIG_PATH" > "$POD_DIR/config.yml" 2>/dev/null || \
    echo "❌ Failed to fetch config" | tee "$POD_DIR/config.yml"

  # 2. Init container logs
  kubectl logs -n "$NAMESPACE" "$pod" -c "$INIT_CONTAINER" > "$POD_DIR/init-container.log" 2>/dev/null || \
    echo "❌ Failed to fetch init container logs" | tee "$POD_DIR/init-container.log"

  # 3. JVM info
  kubectl exec -n "$NAMESPACE" "$pod" -- sh -c '
    pid=$(jcmd | grep -m1 aerospike-vector | awk "{print \$1}")
    if [ -z "$pid" ]; then
      echo "❌ No Java process found via jcmd" | tee "$POD_DIR/jvm-info.txt"
    else
      echo "➡️ jcmd $pid VM.flags:"
      jcmd "$pid" VM.flags
      echo ""
      echo "➡️ jcmd $pid GC.heap_info:"
      jcmd "$pid" GC.heap_info
    fi
  ' > "$POD_DIR/jvm-info.txt" 2>/dev/null || \
    echo "❌ jcmd not available in $pod" | tee "$POD_DIR/jvm-info.txt"

  # 4. GC class histogram
  kubectl exec -n "$NAMESPACE" "$pod" -- sh -c '
    pid=$(jcmd | grep -m1 aerospike-vector | awk "{print \$1}")
    if [ ! -z "$pid" ]; then
      jcmd "$pid" GC.class_histogram
    fi
  ' > "$POD_DIR/gc-class-histogram.txt" 2>/dev/null || \
    echo "❌ GC.class_histogram unavailable" | tee "$POD_DIR/gc-class-histogram.txt"

  # Append to full context
  {
    echo "=============================="
    echo "🧵 POD: $pod"
    echo "=============================="
    echo "Running on node: $NODE_NAME"
    echo "------------------------------"
    cat "$NODE_DIR/node-info.txt"
    echo -e "\n"

    # Only include these files in the GPT context
    for file in config.yml init-container.log jvm-info.txt; do
      if [ -f "$POD_DIR/$file" ]; then
        echo -e "\n📄 FILE: $file"
        echo "------------------------------"
        cat "$POD_DIR/$file"
      fi
    done

    echo -e "\n\n"
  } >> "$TMP_FILE"

  echo "✅ Finished pod: $pod"
# Loop through pods
for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
    collect_pod_info $pod
    
done

# GPT prompt
PROMPT=$(cat <<EOF
The user is a senior engineer with expertise in Aerospike database, Aerospike Kubernetes Operator, Aerospike Vector Search internals, Java/JVM performance tuning, garbage collection diagnostics, and Kubernetes.

You will analyze diagnostics for a single pod in a vector search cluster.

For this pod:
- 🔍 Review 'aerospike-vector-search.yml': validate node roles, heartbeat seeds, listener addresses, and interconnect settings.
- 📦 Summarize JVM flags, especially memory/Garbage Collector settings.
- 📈 Analyze GC.heap_info and GC.class_histogram for pressure or leaks.
- 🛠️ Highlight any failed config-injection logs.

Provide specific recommendations for this node's configuration and performance.
Add identifiers for all pods and nodes so they can be referenced in the analysis.
EOF
)

# Loop through pods for individual analysis
for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
  echo "🤖 Analyzing pod $pod with OpenAI (GPT-4)..."
  POD_TMP_FILE="$OUTPUT_DIR/$pod/pod-context.txt"
  POD_MARKDOWN_REPORT="$OUTPUT_DIR/$pod/analysis.md"
  POD_TEXT_SUMMARY="$OUTPUT_DIR/$pod/summary-report.txt"
  POD_RESPONSE_FILE="$OUTPUT_DIR/$pod/response.json"
  POD_REQUEST_FILE="$OUTPUT_DIR/$pod/request.json"  
  # Create pod-specific context
  {
    echo "=============================="
    echo "🧵 POD: $pod"
    echo "=============================="

    for file in config.yml init-container.log jvm-info.txt; do
      if [ -f "$OUTPUT_DIR/$pod/$file" ]; then
        echo -e "\n📄 FILE: $file"
        echo "------------------------------"
        cat "$OUTPUT_DIR/$pod/$file"
      fi
    done
  } > "$POD_TMP_FILE"

  # Create the request JSON
  {
    echo '{
      "model": "'"$MODEL"'",
      "temperature": 0.3,
      "messages": [
        {
          "role": "system",
          "content": "'"$PROMPT"'"
        },
        {
          "role": "user",
          "content": "'"$(cat "$POD_TMP_FILE" | sed 's/"/\\"/g')"'"
        }
      ]
    }'
  } > "$POD_REQUEST_FILE"

  # Make the API call using the request file
  curl https://api.openai.com/v1/chat/completions \
    -sS \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$POD_REQUEST_FILE" > "$POD_RESPONSE_FILE"
 
    echo "openai response: $(cat $POD_RESPONSE_FILE)"
    cat "$POD_RESPONSE_FILE" | jq -r '.choices[0].message.content' \
    | tee "$POD_MARKDOWN_REPORT" | tee "$POD_TEXT_SUMMARY"

  # Clean up temporary files
#   rm "$POD_TMP_FILE" "$POD_REQUEST_FILE"

  echo "✅ Analysis for pod $pod complete"
  echo "  - Markdown report: $POD_MARKDOWN_REPORT"
  echo "  - Text summary: $POD_TEXT_SUMMARY"
done

# Create a cluster summary
echo "# Aerospike Vector Search Cluster Analysis" > "$MARKDOWN_REPORT"
echo -e "\n## Individual Pod Reports\n" >> "$MARKDOWN_REPORT"

for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
  echo -e "\n### Pod: $pod\n" >> "$MARKDOWN_REPORT"
  cat "$OUTPUT_DIR/$pod/analysis.md" >> "$MARKDOWN_REPORT"
done

cp "$MARKDOWN_REPORT" "$TEXT_SUMMARY"

echo "✅ Individual pod analysis complete"
echo "✅ Cluster summary written to: $MARKDOWN_REPORT"
echo "✅ Text summary written to: $TEXT_SUMMARY"
echo "🎉 Full bundle inspection and analysis complete!"
