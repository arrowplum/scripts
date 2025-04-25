#!/bin/bash

set -euo pipefail

# === Configuration ===
OPENAI_API_KEY="${OPENAI_API_KEY:-}"  # Must be exported before running
NAMESPACE="avs"
MODEL="gpt-4o"
TEMP_DIR="/tmp/akoctl_analysis"
SUMMARY_FILE="$TEMP_DIR/cluster_summary.txt"
ANALYSIS_FILE="$TEMP_DIR/analysis.md"
MAX_BYTES_PER_FILE=2000  # Reduced from 10000
SYSTEM_PROMPT="You are a senior site reliability engineer and software engineer with deep\
 expertise in Aerospike database architecture, Aerospike Kubernetes Operator, \
 Aerospike Vector Search internals, Java/JVM performance tuning and GC diagnostics, and Kubernetes.\
  Review this  cluster diagnostics bundle summarize nodes and pods memory and cpu usage for aerospike and avs namespacesand analyze: 1) Configuration patterns and pod/node inconsistencies, 2) Resource allocation and JVM/GC-based scaling recommendations, 3) \
  Storage configuration and StatefulSet/PV performance, 4) Network and service connectivity, 5) Critical issues needing immediate attention, 6) JVM/GC optimization suggestions. Provide specific recommendations and an executive summary  Be precise and opinionated in your recommendations. Please ignore image pull secrets issues. The AVS cluster is heterogeneous with nodes with different labels and node pools having different configurations and hardware. please deeply analize any avs nodes that have problems or are failing readiness probes. Provide kubernetes commands that would help debug issues especially for failures. Please also report on a summary of instance types, \
  memory and cpu usage, and other metrics. "

# === Ensure Input Provided ===
if [ $# -ne 1 ]; then
  echo "Usage: $0 path/to/akoctl_collectinfo.tar.gz"
  exit 1
fi
TARBALL="$1"

# === Prep workspace ===
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
tar -xzf "$TARBALL" -C "$TEMP_DIR"

# === Extract relevant logs/configs ===
echo "📦 Extracting important logs and configs..."
find "$TEMP_DIR" \( \
  -path "*/k8s_namespaces/avs/*" -o \
  -path "*/k8s_namespaces/aerospike/*" -o \
  -path "*/k8s_cluster/nodes/*" -o \
  -path "*/k8s_cluster/persistentvolumes/*" -o \
  -path "*/k8s_cluster/storageclasses/*" -o \
  -path "*/k8s_cluster/summary/*" \
\) -a \( -type f \) -a \( -name "*.yaml" -o -name "*.log" -o -name "*.txt" \) | sort > "$TEMP_DIR/file_list.txt"

# Function to check if file is important
is_important_file() {
    local file="$1"
    case "$file" in
        *"pod.yaml" | *"deployment.yaml" | *"statefulset.yaml" | \
        *"configmap.yaml" | *"pvc.yaml" | *"events.txt" | \
        *"describe.txt" | *"logs.txt" | *"status.txt")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# Function to get file summary
get_file_summary() {
    local file="$1"
    local max_bytes="$2"
    
    if [[ "$file" == *"logs.txt" ]]; then
        # For log files, take first few lines and last few lines
        {
            head -n 20 "$file"
            echo -e "\n... [logs truncated] ...\n"
            tail -n 20 "$file"
        } | head -c "$max_bytes"
    else
        # For other files, take from the start
        head -c "$max_bytes" "$file"
    fi
}

# === Build summary text ===
echo "📝 Building summary context for GPT..."
{
    echo "# Kubernetes Cluster Analysis Bundle"
    echo "Generated: $(date)"
    echo
    
    # First process important files
    while IFS= read -r file; do
        if is_important_file "$file"; then
            relative_path="${file#$TEMP_DIR/}"
            echo -e "\n=== IMPORTANT FILE: $relative_path ==="
            if [ -f "$file" ]; then
                get_file_summary "$file" "$MAX_BYTES_PER_FILE"
                echo -e "\n[Content truncated at $MAX_BYTES_PER_FILE bytes]\n"
            else
                echo "[File not found]"
            fi
        fi
    done < "$TEMP_DIR/file_list.txt"
    
    # Then process other files with more aggressive truncation
    echo -e "\n=== OTHER RELEVANT FILES ===\n"
    while IFS= read -r file; do
        if ! is_important_file "$file"; then
            relative_path="${file#$TEMP_DIR/}"
            echo -e "\n--- FILE: $relative_path ---"
            if [ -f "$file" ]; then
                get_file_summary "$file" $((MAX_BYTES_PER_FILE / 2))
                echo -e "\n[Content truncated at $((MAX_BYTES_PER_FILE / 2)) bytes]\n"
            else
                echo "[File not found]"
            fi
        fi
    done < "$TEMP_DIR/file_list.txt"
} > "$SUMMARY_FILE"

# === Build JSON request for OpenAI ===
echo "🤖 Preparing API request..."
REQUEST_FILE="$TEMP_DIR/request.json"
CONTENT_FILE="$TEMP_DIR/content.json"

# First encode the content and system prompt as JSON strings
SYSTEM_JSON=$(echo "$SYSTEM_PROMPT" | jq -R '. as $raw | $raw')
CONTENT_JSON=$(cat "$SUMMARY_FILE" | jq -Rs '. as $raw | $raw')

# Create the full request JSON
cat > "$REQUEST_FILE" << EOF
{
  "model": "$MODEL",
  "temperature": 0.3,
  "messages": [
    {
      "role": "system",
      "content": $SYSTEM_JSON
    },
    {
      "role": "user",
      "content": $CONTENT_JSON
    }
  ]
}
EOF

# Validate JSON before sending
if ! jq '.' "$REQUEST_FILE" > /dev/null 2>&1; then
  echo "Error: Generated invalid JSON"
  exit 1
fi

echo "🤖 Sending to GPT-4 for analysis..."
RESPONSE=$(curl https://api.openai.com/v1/chat/completions \
  -sS \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d @"$REQUEST_FILE")

if ! echo "$RESPONSE" | jq -e '.choices[0].message.content' >/dev/null; then
  echo "Error in API response:"
  echo "$RESPONSE" | jq '.'
  exit 1
fi

echo "$RESPONSE" | jq -r '.choices[0].message.content' > "$ANALYSIS_FILE"
echo "✅ Analysis complete. Saved to: $ANALYSIS_FILE"

# Print the analysis
echo -e "\n=== Analysis Results ===\n"
cat "$ANALYSIS_FILE"

# Clean up temporary files
rm -f "$CONTENT_FILE"
rm -f "$REQUEST_FILE"
