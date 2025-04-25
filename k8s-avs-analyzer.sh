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

# === Configuration ===
NAMESPACE="${NAMESPACE:-avs}"
MODEL="gpt-4"
TEMP_DIR="/tmp/avs_analysis"
OUTPUT_DIR="./avs-inspection-output"
MAX_BYTES_PER_FILE=2000

# Ensure OpenAI API key is set
if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "❌ OPENAI_API_KEY environment variable must be set"
    exit 1
fi

# Check for required tools
for cmd in kubectl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Required command '$cmd' not found"
        exit 1
    fi
done

# # Check if akoctl plugin is installed
# if ! kubectl plugin list | grep -q "akoctl"; then
#     echo "❌ kubectl-akoctl plugin not found"
#     echo "Install akoctl with:"
#     echo "  kubectl krew index add akoctl https://github.com/aerospike/aerospike-kubernetes-operator-ctl.git"
#     echo "  kubectl krew install akoctl/akoctl"
#     exit 1
# fi

# === Functions ===
is_important_file() {
    local file="$1"
    case "$file" in
        *"pod.yaml" | *"deployment.yaml" | *"statefulset.yaml" | \
        *"configmap.yaml" | *"pvc.yaml" | *"events.txt" | \
        *"describe.txt" | *"logs.txt" | *"status.txt" | \
        *"gc-class-histogram.txt" | *"jvm-info.txt")
            return 0 ;;
        *)
            return 1 ;;
    esac
}

get_file_summary() {
    local file="$1"
    local max_bytes="$2"
    
    # Check if file exists and has content
    if [ ! -s "$file" ]; then
        echo "[No data available]"
        return
    fi
    
    if [[ "$file" == *"logs.txt" ]]; then
        {
            head -n 20 "$file"
            echo -e "\n... [logs truncated] ...\n"
            tail -n 20 "$file"
        } | head -c "$max_bytes"
    # elif [[ "$file" == *"gc-class-histogram.txt" ]]; then


        # Check if file contains actual histogram data
        # if grep -q "num" "$file" 2>/dev/null; then
        #     {
        #         head -n 3 "$file"  # Header
        #         echo -e "\nTop 20 memory consumers:"
        #         tail -n +4 "$file" | head -n 20  # Top 20 entries
        #         echo -e "\nTotal memory statistics:"
        #         tail -n +4 "$file" | awk '
        #             { instances += $2; bytes += $3 }
        #             END { 
        #                 if (NR > 0) {
        #                     printf "Total Instances: %d\nTotal Bytes: %d\nAvg Bytes/Instance: %.2f\n", 
        #                         instances, bytes, (bytes/instances)
        #                 } else {
        #                     print "No data available for statistics"
        #                 }
        #             }'
        #     } | head -c "$max_bytes"
        # else
        #     echo "[No GC histogram data available]"
        #     return
        # fi
    else
        head -c "$max_bytes" "$file"
    fi
}

collect_pod_info() {
    local pod="$1"
    local pod_dir="$OUTPUT_DIR/$pod"
    mkdir -p "$pod_dir"
    
    echo "🔍 Inspecting pod: $pod"
    
    # Collect pod configuration
    kubectl get pod "$pod" -n "$NAMESPACE" -o yaml > "$pod_dir/pod.yaml" 2>/dev/null || \
        echo "❌ Failed to fetch pod config" > "$pod_dir/pod.yaml"
    
    # Collect JVM info with timeout
    timeout 10s kubectl exec -n "$NAMESPACE" "$pod" -- sh -c '
        pid=$(jcmd | grep -m1 aerospike-vector | awk "{print \$1}")
        if [ -z "$pid" ]; then
            echo "❌ No Java process found"
            exit 1
        else
            echo "=== JVM Flags ==="
            jcmd "$pid" VM.flags
            echo -e "\n=== Heap Info ==="
            jcmd "$pid" GC.heap_info
        fi
    ' > "$pod_dir/jvm-info.txt" 2>/dev/null || \
        echo "❌ Failed to fetch JVM info" > "$pod_dir/jvm-info.txt"
    
    # Collect GC histogram with timeout
    timeout 10s kubectl exec -n "$NAMESPACE" "$pod" -- sh -c '
        pid=$(jcmd | grep -m1 aerospike-vector | awk "{print \$1}")
        if [ ! -z "$pid" ]; then
            jcmd "$pid" GC.class_histogram
        else
            echo "❌ No Java process found"
            exit 1
        fi
    ' > "$pod_dir/gc-class-histogram.txt" 2>/dev/null || \
        echo "❌ Failed to fetch GC histogram" > "$pod_dir/gc-class-histogram.txt"
}

collect_cluster_info() {
    local output_dir="$1"
    echo "📦 Collecting cluster information with kubectl akoctl..."
    
    # Create a specific directory for akoctl output
    local akoctl_dir="$output_dir/akoctl_output"
    mkdir -p "$akoctl_dir"
    
    # Use kubectl akoctl to collect comprehensive cluster information
    kubectl akoctl collectinfo -n "$NAMESPACE" --path "$akoctl_dir"
    
    # Find and extract the latest akoctl_collectinfo file
    local tarfile
    tarfile=$(find "$akoctl_dir" -name "akoctl_collectinfo_*.tar.gzip" -type f -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
    
    if [ -z "$tarfile" ]; then
        echo "❌ No akoctl_collectinfo file found in $akoctl_dir"
        echo "The akoctl collectinfo command did not generate expected output"
        exit 1
    fi
    
    echo "📦 Extracting cluster information from $(basename "$tarfile")..."
    tar xf "$tarfile" -C "$output_dir"
    rm "$tarfile"
}

process_akoctl_info() {
    local input_dir="$1"
    local output_file="$2"
    local max_bytes="$3"
    
    {
        echo "=== Kubernetes Cluster Information ==="
        echo "Collected at: $(date)"
        echo
        
        # Process cluster-level information
        if [ -d "$input_dir/k8s_cluster" ]; then
            echo "=== Cluster Resources ==="
            
            # Process nodes
            if [ -d "$input_dir/k8s_cluster/nodes" ]; then
                echo -e "\n--- Nodes ---"
                for f in "$input_dir/k8s_cluster/nodes"/*.yaml; do
                    [ -f "$f" ] || continue
                    echo -e "\nNode: $(basename "$f" .yaml)"
                    head -c "$max_bytes" "$f"
                done
            fi
            
            # Process storage classes
            if [ -d "$input_dir/k8s_cluster/storageclasses" ]; then
                echo -e "\n--- Storage Classes ---"
                for f in "$input_dir/k8s_cluster/storageclasses"/*.yaml; do
                    [ -f "$f" ] || continue
                    echo -e "\nStorageClass: $(basename "$f" .yaml)"
                    head -c "$max_bytes" "$f"
                done
            fi
            
            # Process PVs
            if [ -d "$input_dir/k8s_cluster/persistentvolumes" ]; then
                echo -e "\n--- Persistent Volumes ---"
                for f in "$input_dir/k8s_cluster/persistentvolumes"/*.yaml; do
                    [ -f "$f" ] || continue
                    echo -e "\nPV: $(basename "$f" .yaml)"
                    head -c "$max_bytes" "$f"
                done
            fi
        fi
        
        # Process namespace information
        if [ -d "$input_dir/k8s_namespaces/$NAMESPACE" ]; then
            echo -e "\n=== Namespace: $NAMESPACE ==="
            
            # Process events
            if [ -f "$input_dir/k8s_namespaces/$NAMESPACE/summary/events.txt" ]; then
                echo -e "\n--- Events ---"
                head -c "$max_bytes" "$input_dir/k8s_namespaces/$NAMESPACE/summary/events.txt"
            fi
            
            # Process Aerospike clusters
            if [ -d "$input_dir/k8s_namespaces/$NAMESPACE/aerospikeclusters" ]; then
                echo -e "\n--- Aerospike Clusters ---"
                for f in "$input_dir/k8s_namespaces/$NAMESPACE/aerospikeclusters"/*.yaml; do
                    [ -f "$f" ] || continue
                    echo -e "\nCluster: $(basename "$f" .yaml)"
                    head -c "$max_bytes" "$f"
                done
            fi
            
            # Process StatefulSets
            if [ -d "$input_dir/k8s_namespaces/$NAMESPACE/statefulsets" ]; then
                echo -e "\n--- StatefulSets ---"
                for f in "$input_dir/k8s_namespaces/$NAMESPACE/statefulsets"/*.yaml; do
                    [ -f "$f" ] || continue
                    echo -e "\nStatefulSet: $(basename "$f" .yaml)"
                    head -c "$max_bytes" "$f"
                done
            fi
        fi
    } > "$output_file"
}

analyze_with_gpt() {
    local context_file="$1"
    local output_file="$2"
    local prompt="$3"
    local request_file="${TEMP_DIR}/request.json"
    
    # Encode content as JSON
    local content_json
    content_json=$(jq -Rs '.' < "$context_file")
    local prompt_json
    prompt_json=$(echo "$prompt" | jq -R '.')
    
    # Create request JSON
    cat > "$request_file" << EOF
{
    "model": "$MODEL",
    "temperature": 0.3,
    "messages": [
        {
            "role": "system",
            "content": $prompt_json
        },
        {
            "role": "user",
            "content": $content_json
        }
    ]
}
EOF
    
    # Validate JSON
    if ! jq '.' "$request_file" > /dev/null 2>&1; then
        echo "Error: Invalid JSON generated"
        exit 1
    fi
    
    # Make API call
    local response
    response=$(curl https://api.openai.com/v1/chat/completions \
        -sS \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$request_file")
    
    if ! echo "$response" | jq -e '.choices[0].message.content' >/dev/null; then
        echo "Error in API response:"
        echo "$response" | jq '.'
        exit 1
    fi
    
    echo "$response" | jq -r '.choices[0].message.content' > "$output_file"
    rm -f "$request_file"
}

# === Main Script ===
echo "📦 Starting AVS cluster analysis..."

# Clean up and create directories
rm -rf "$OUTPUT_DIR" "$TEMP_DIR"
mkdir -p "$OUTPUT_DIR" "$TEMP_DIR"

# Collect cluster information using akoctl
collect_cluster_info "$TEMP_DIR"

# Process akoctl information
CLUSTER_INFO_FILE="$TEMP_DIR/cluster_info.txt"
process_akoctl_info "$TEMP_DIR/akoctl_collectinfo" "$CLUSTER_INFO_FILE" "$MAX_BYTES_PER_FILE"

# Get list of pods
PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}')

# Collect info for each pod
for pod in $PODS; do
    collect_pod_info "$pod"
done

# Analyze each pod individually
POD_PROMPT="You are an expert in Aerospike Vector Search and JVM performance. Analyze this pod's configuration and metrics. Focus on:
1. JVM configuration and memory settings
2. GC behavior and potential memory leaks
3. Performance bottlenecks
4. Configuration issues
Provide specific recommendations for optimization."

for pod in $PODS; do
    echo "🤖 Analyzing pod: $pod"
    pod_context="$TEMP_DIR/${pod}_context.txt"
    pod_analysis="$OUTPUT_DIR/${pod}/analysis.md"
    
    # Create pod context with cluster info
    {
        echo "=== Cluster Context ==="
        cat "$CLUSTER_INFO_FILE"
        
        echo -e "\n=== Pod Analysis: $pod ==="
        for file in "$OUTPUT_DIR/$pod"/*; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")
                echo -e "\n=== $filename ===\n"
                get_file_summary "$file" "$MAX_BYTES_PER_FILE"
            fi
        done
    } > "$pod_context"
    
    analyze_with_gpt "$pod_context" "$pod_analysis" "$POD_PROMPT"
done

# Create cluster-wide summary with enhanced context
echo "🤖 Creating cluster-wide analysis..."
CLUSTER_PROMPT="You are an expert in Kubernetes and Aerospike Vector Search clusters. Review the cluster information and individual pod analyses to create a comprehensive cluster-wide summary. Focus on:
1. Cluster-wide patterns and issues
2. Configuration consistency across pods and nodes
3. Resource allocation and scaling recommendations
4. Storage configuration and performance
5. Critical issues that need immediate attention
6. Network configuration and connectivity
Provide actionable recommendations for improving cluster health and performance."

cluster_context="$TEMP_DIR/cluster_context.txt"
{
    echo "=== Cluster Information ==="
    cat "$CLUSTER_INFO_FILE"
    
    echo -e "\n=== Individual Pod Analyses ===\n"
    for pod in $PODS; do
        echo -e "\n--- $pod Analysis ---\n"
        cat "$OUTPUT_DIR/$pod/analysis.md"
    done
} > "$cluster_context"

analyze_with_gpt "$cluster_context" "$OUTPUT_DIR/cluster-analysis.md" "$CLUSTER_PROMPT"

echo "✅ Analysis complete!"
echo "📊 Individual pod analyses are in: $OUTPUT_DIR/<pod-name>/analysis.md"
echo "📈 Cluster-wide analysis is in: $OUTPUT_DIR/cluster-analysis.md" 