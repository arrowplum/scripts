#!/bin/bash
# Add line numbers to debug output by modifying PS4
export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR

# Error handling functions
handle_error() {
  local lineno=$1
  echo "❌ Script exited with error at line $lineno" >&2
  exit 1
}

# Function to safely cat a file or warn if missing

# Function to safely make API calls and log errors
safe_api_call() {
    local request_file="$1"
    local response_file="$2"
    local context="$3"
    local error_log="$OUTPUT_DIR/curl-errors.log"
    
    curl https://api.openai.com/v1/chat/completions \
        -sS \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$request_file" > "$response_file"
    
    local curl_exit_code=$?
    if [ $curl_exit_code -ne 0 ] || ! jq -e '.choices[0].message.content' "$response_file" >/dev/null 2>&1; then
        echo "❌ [ERROR] curl request failed for $context (exit code $curl_exit_code)" >&2
        echo "---- curl error for $context ----" >> "$error_log"
        cat "$response_file" >> "$error_log"
        echo "-----------------------------------" >> "$error_log"
        return 1
    fi
    return 0
}

# set -euo pipefail
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

# Function to collect node information
collect_node_info() {
    local node="$1"
    local NODE_DIR="$OUTPUT_DIR/nodes/$node"
    mkdir -p "$NODE_DIR"

    echo "📊 Collecting node information for: $node"
    
    # Check if node is reachable
    if ! kubectl get node "$node" &>/dev/null; then
        echo "⚠️ Node $node is not reachable. Collecting limited information." >&2
        {
            echo "=== Node Status ==="
            echo "Node is not reachable"
            echo "Last known status: $(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")"
            echo "Last known reason: $(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "Unknown")"
            echo "Last known message: $(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "Unknown")"
            
            echo -e "\n=== Recent Events ==="
            kubectl get events --field-selector involvedObject.name="$node" --sort-by='.lastTimestamp' 2>/dev/null || echo "No events found"
        } > "$NODE_DIR/node-info.txt"
        return
    fi

    {
        echo "=== Node Description ==="
        kubectl describe node "$node" || echo "Failed to describe node" >&2
        
        echo -e "\n=== Node Resources ==="
        # Get actual memory values in GiB
        local total_memory=$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}' | sed 's/Ki//' | awk '{printf "%.2f", $1/1024/1024}')
        local allocatable_memory=$(kubectl get node "$node" -o jsonpath='{.status.allocatable.memory}' | sed 's/Ki//' | awk '{printf "%.2f", $1/1024/1024}')
        echo "Total Memory: ${total_memory}GiB"
        echo "Allocatable Memory: ${allocatable_memory}GiB"
        
        echo -e "\n=== Node Allocatable Resources ==="
        kubectl get node "$node" -o json | jq '.status.allocatable' || echo "Failed to get allocatable resources" >&2
        
        echo -e "\n=== Node Conditions ==="
        kubectl get node "$node" -o json | jq '.status.conditions' || echo "Failed to get node conditions" >&2
        
        echo -e "\n=== Cloud Instance Information ==="
        # Get common labels
        local labels=$(kubectl get node "$node" -o json | jq -r '.metadata.labels' || echo "{}")
        
        # Determine cloud provider and get instance type
        local cloud_provider="On-premises"
        local instance_type="Unknown"
        
        # Check for Azure
        if echo "$labels" | jq -e '."kubernetes.azure.com"' >/dev/null; then
            cloud_provider="Azure"
            # Try multiple possible labels for Azure instance type
            instance_type=$(echo "$labels" | jq -r '."node.kubernetes.io/instance-type" // "N/A"')
            if [ "$instance_type" = "N/A" ]; then
                instance_type=$(echo "$labels" | jq -r '."beta.kubernetes.io/instance-type" // "N/A"')
            fi
        # Check for AWS
        elif echo "$labels" | jq -e '."eks.amazonaws.com"' >/dev/null; then
            cloud_provider="AWS"
            instance_type=$(echo "$labels" | jq -r '."node.kubernetes.io/instance-type" // "N/A"')
        # Check for GCP
        elif echo "$labels" | jq -e '."cloud.google.com"' >/dev/null; then
            cloud_provider="GCP"
            instance_type=$(echo "$labels" | jq -r '."cloud.google.com/machine-type" // "N/A"')
        fi

        # Get region and zone
        local region=$(echo "$labels" | jq -r '."topology.kubernetes.io/region" // "N/A"')
        local zone=$(echo "$labels" | jq -r '."topology.kubernetes.io/zone" // "N/A"')

        echo "Cloud Provider: $cloud_provider"
        echo "Instance Type: $instance_type"
        echo "Region: $region"
        echo "Zone: $zone"
        echo "CPU Cores: $(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}')"
        echo "Memory: ${total_memory}GiB total, ${allocatable_memory}GiB allocatable"

        echo -e "\n=== OOMKill Events ==="
        # Get system OOM events from kernel logs with full messages
        echo "System OOM Events:"
        kubectl debug node/"$node" -it --image=ubuntu -- dmesg | grep -i "oom-killer" || echo "No system OOM events found" >&2
        
        # Get Kubernetes OOM events with full messages
        echo -e "\nKubernetes OOMKill Events:"
        kubectl get events -n "$NAMESPACE" --field-selector type=Warning | grep -i "OOMKilled" || echo "No Kubernetes OOM events found" >&2

        echo -e "\n=== Node OOMKill Events ==="
        # 1. Get system OOM events with full messages
        echo "System OOM Events (last 24h):"
        # Using debug node to access system logs
        kubectl debug node/"$node" -it --image=ubuntu -- journalctl --since "24 hours ago" | grep -i "oom-killer" || \
            echo "No system OOM events found" >&2

        # 2. Get all pod OOMKills on this node with full messages
        echo -e "\nPod OOMKills on this node:"
        kubectl get pods -A -o json --field-selector spec.nodeName="$node" | \
            jq '.items[] | select(.status.containerStatuses != null) | 
                .status.containerStatuses[] | select(.lastState.terminated.reason=="OOMKilled") |
                "Pod \(.name) OOMKilled at \(.lastState.terminated.finishedAt)\nMessage: \(.lastState.terminated.message)\nExit Code: \(.lastState.terminated.exitCode)"' || \
            echo "No pod OOMKills found" >&2
    } > "$NODE_DIR/node-info.txt"
}

# Function to collect pod information
collect_pod_info() {
    local pod="$1"
    local node="$2"
    local POD_DIR="$OUTPUT_DIR/nodes/$node/pods/$pod"
    mkdir -p "$POD_DIR"

    echo "📊 Collecting pod information for: $pod on node: $node"
    
    # Check if pod is reachable
    if ! kubectl get pod -n "$NAMESPACE" "$pod" &>/dev/null; then
        echo "⚠️ Pod $pod is not reachable. Collecting limited information." >&2
        {
            echo "=== Pod Status ==="
            echo "Pod is not reachable"
            echo "Last known status: $(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")"
            echo "Last known reason: $(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.reason}' 2>/dev/null || echo "Unknown")"
            echo "Last known message: $(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.message}' 2>/dev/null || echo "Unknown")"
            
            echo -e "\n=== Recent Events ==="
            kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$pod" --sort-by='.lastTimestamp' 2>/dev/null || echo "No events found" >&2
            
            echo -e "\n=== Previous Container Terminations ==="
            kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.containerStatuses[*].lastState}' 2>/dev/null || echo "No previous container terminations found" >&2
        } > "$POD_DIR/pod-info.txt"
        return
    fi

    {
        echo "=== Pod Description ==="
        kubectl describe pod -n "$NAMESPACE" "$pod" || echo "Failed to describe pod" >&2
        
        echo -e "\n=== Pod Resources ==="
        # Get actual memory values in GiB
        local memory_request=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.containers[0].resources.requests.memory}' | sed 's/Ki//' | awk '{printf "%.2f", $1/1024/1024}')
        local memory_limit=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.containers[0].resources.limits.memory}' | sed 's/Ki//' | awk '{printf "%.2f", $1/1024/1024}')
        echo "Memory Request: ${memory_request}GiB"
        echo "Memory Limit: ${memory_limit}GiB"
        
        echo -e "\n=== Pod Conditions ==="
        kubectl get pod -n "$NAMESPACE" "$pod" -o json | jq '.status.conditions' || echo "Failed to get pod conditions" >&2
        
        echo -e "\n=== OOMKill Events ==="
        # Get pod OOMKill events with full messages
        echo "Pod OOMKill Events:"
        kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$pod",type=Warning | grep -i "OOMKilled" || echo "No OOMKill events found" >&2
        
        # Get container OOMKill history with full messages
        echo -e "\nContainer OOMKill History:"
        kubectl get pod -n "$NAMESPACE" "$pod" -o json | \
            jq '.status.containerStatuses[] | select(.lastState.terminated.reason=="OOMKilled") |
                "Container \(.name) OOMKilled at \(.lastState.terminated.finishedAt)\nMessage: \(.lastState.terminated.message)\nExit Code: \(.lastState.terminated.exitCode)"' || \
            echo "No container OOMKills found" >&2
        
        echo -e "\n=== JVM Memory Settings ==="
        # Get JVM memory settings from pod logs
        kubectl logs -n "$NAMESPACE" "$pod" | grep -i "Xmx\|Xms" || echo "No JVM memory settings found in logs" >&2
        
        echo -e "\n=== Current Memory Usage ==="
        kubectl top pod -n "$NAMESPACE" "$pod" || echo "Failed to get current memory usage" >&2
    } > "$POD_DIR/pod-info.txt"
}

# First, collect all node information
echo "🌐 Collecting node information..."
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    collect_node_info "$node"
done

# Then, process AVS pods on each node
echo "📦 Processing AVS pods..."
for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
    node=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.nodeName}')
    collect_pod_info "$pod" "$node"
done

# NEW CODE STARTS HERE
# GPT prompt for node analysis
NODE_PROMPT=$(cat <<EOF
You are analyzing a Kubernetes node and its Aerospike Vector Search pods.

For this node:
- 🖥️ Analyze node capacity, allocatable resources, and conditions
- 🏷️ Review cloud provider details and instance type
- 📊 Evaluate resource allocation and utilization
- 🔍 Check for any node-level issues or warnings

For each AVS pod on this node:
- 🔍 Review 'aerospike-vector-search.yml': validate node roles, heartbeat seeds, listener addresses, and interconnect settings
- 📦 Summarize JVM flags, especially memory/Garbage Collector settings
- 📈 Analyze GC.heap_info and GC.class_histogram for pressure or leaks
- 🛠️ Highlight any failed config-injection logs

Provide specific recommendations for:
1. Node-level optimizations
2. Pod-level configurations
3. Resource allocation adjustments
4. Performance improvements

Include specific identifiers for the node and pods in your analysis.
EOF
)

# Analyze each node and its pods
echo "🤖 Analyzing nodes and their pods..."
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    echo "Analyzing node: $node"
    NODE_DIR="$OUTPUT_DIR/nodes/$node"
    NODE_ANALYSIS_FILE="$NODE_DIR/analysis.md"
    NODE_TMP_FILE="$NODE_DIR/node-context.txt"
    NODE_REQUEST_FILE="$NODE_DIR/request.json"
    NODE_RESPONSE_FILE="$NODE_DIR/response.json"

    # Create node context including its pods
  {
    echo "=============================="
        echo "🖥️ NODE: $node"
    echo "=============================="
        echo -e "\n=== Node Information ==="
        cat "$NODE_DIR/node-info.txt"
        
        # Find and include information for all AVS pods on this node
        if [ -d "$NODE_DIR/pods" ]; then
            echo -e "\n=== AVS Pods on Node ==="
            for pod_dir in "$NODE_DIR/pods"/*; do
                if [ -d "$pod_dir" ]; then
                    pod=$(basename "$pod_dir")
                    echo -e "\n🧵 POD: $pod"
                    echo "------------------------------"
    for file in config.yml init-container.log jvm-info.txt; do
                        if [ -f "$pod_dir/$file" ]; then
        echo -e "\n📄 FILE: $file"
        echo "------------------------------"
                            cat "$pod_dir/$file"
                        fi
                    done
      fi
    done
        else
            echo -e "\n❌ No AVS pods found on this node"
        fi
    } > "$NODE_TMP_FILE"

    # Create the request JSON
    {
        echo '{
            "model": "'"$MODEL"'",
            "temperature": 0.3,
            "messages": [
                {
                    "role": "system",
                    "content": "'"$NODE_PROMPT"'"
                },
                {
                    "role": "user",
                    "content": "'"$(cat "$NODE_TMP_FILE" | sed 's/"/\\"/g')"'"
                }
            ]
        }'
    } > "$NODE_REQUEST_FILE"

    # Make the API call with error handling
    if ! safe_api_call "$NODE_REQUEST_FILE" "$NODE_RESPONSE_FILE" "node $node"; then
        echo "⚠️ Skipping analysis for node $node due to API error" >&2
        continue
    fi

    echo "GPT Analysis for node $node"
    cat "$NODE_RESPONSE_FILE" | jq -r '.choices[0].message.content' | tee "$NODE_ANALYSIS_FILE"

    echo "✅ Analysis for node $node complete"
    echo "  - Analysis report: $NODE_ANALYSIS_FILE"
done

# Cluster analysis prompt
CLUSTER_PROMPT=$(cat <<EOF
You are analyzing an Aerospike Vector Search cluster deployment.

Generate a comprehensive cluster analysis report with the following sections:

1. Resource Overview Table
   - Create a table showing each node's:
     * Instance Type (exact type from node info)
     * Total Memory (in GiB)
     * Allocatable Memory (in GiB)
     * AVS Pod Memory (Requested vs Used, in GiB)
     * Status/Health

2. Cluster Health Assessment
   - Memory distribution across nodes
   - Resource allocation patterns
   - GC pressure indicators
   - Node conditions

3. Key Metrics
   - Total cluster memory
   - Average memory per AVS pod
   - Memory utilization percentages
   - Resource efficiency

4. Potential Issues
   - Memory pressure points
   - Resource imbalances
   - GC concerns
   - Configuration inconsistencies

5. OOMKill Analysis
   - Detailed timeline of all OOMKill events found:
     * Container restart history
     * Previous termination states
     * System OOM events
     * Pod events
   
   - For each OOMKill event analyze:
     * JVM heap settings at the time
     * Node memory capacity
     * Whether it was an isolated incident or part of a pattern
     * Correlation with memory pressure or other events

6. Memory Configuration Assessment
   - Compare nodes/pods with and without OOMKills
   - Analyze if OOMKills correlate with:
     * Higher heap/node memory ratios
     * Specific workload patterns
     * Time of day or specific events
   
7. Recommendations
   - Specific memory configuration changes
   - System-level improvements
   - Monitoring enhancements
   - Prevention strategies

Provide a clear timeline of OOMKill events and their context.
Highlight patterns and potential root causes.

Pay special attention to:
- Pod restart counts and timing
- Last termination states and reasons
- Exit codes (137 indicates OOMKill)
- Time correlation between restarts and node pressure
- Pattern of restarts across the cluster

When analyzing OOMKills:
1. Look at both container termination states AND system events
2. Check if restarts happened close to memory pressure events
3. Compare memory settings of pods that restarted vs stable pods
4. Consider the timing of restarts relative to pod age

Use the exact instance types and memory values from the node information.
EOF
)

# Function to generate cluster summary
generate_cluster_summary() {
    echo "🤖 Generating cluster-wide analysis..."

    # Create cluster summary context
    CLUSTER_TMP_FILE="$OUTPUT_DIR/cluster-context.txt"
    CLUSTER_REQUEST_FILE="$OUTPUT_DIR/cluster-request.json"
    CLUSTER_RESPONSE_FILE="$OUTPUT_DIR/cluster-response.json"

    # Collect cluster-wide metrics from already gathered data
  {
    echo "=============================="
        echo "🌐 CLUSTER OVERVIEW"
    echo "=============================="

        echo -e "\n=== Node Resources ==="
        for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
            echo -e "\nNode: $node"
            if [ -f "$OUTPUT_DIR/nodes/$node/node-info.txt" ]; then
                # Extract key node information
                echo "Instance Type: $(grep "Instance Type:" "$OUTPUT_DIR/nodes/$node/node-info.txt" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
                echo "Total Memory: $(grep "Total Memory:" "$OUTPUT_DIR/nodes/$node/node-info.txt" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
                echo "Allocatable Memory: $(grep "Allocatable Memory:" "$OUTPUT_DIR/nodes/$node/node-info.txt" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
                echo "CPU Cores: $(grep "CPU Cores:" "$OUTPUT_DIR/nodes/$node/node-info.txt" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
                
                # Get node conditions
                echo -e "\nNode Conditions:"
                grep -A 5 "Node Conditions:" "$OUTPUT_DIR/nodes/$node/node-info.txt" | tail -n +2
            fi
            
            echo -e "\n  AVS Pods:"
            if [ -d "$OUTPUT_DIR/nodes/$node/pods" ]; then
                for pod_dir in "$OUTPUT_DIR/nodes/$node/pods"/*; do
                    if [ -d "$pod_dir" ] && [ -f "$pod_dir/pod-info.txt" ]; then
                        pod=$(basename "$pod_dir")
                        echo -e "\n    Pod: $pod"
                        # Extract key pod information
                        echo "    Memory Request: $(grep "Memory Request:" "$pod_dir/pod-info.txt" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
                        echo "    Memory Limit: $(grep "Memory Limit:" "$pod_dir/pod-info.txt" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
                        echo "    Current Memory Usage: $(grep -A 1 "Current Memory Usage:" "$pod_dir/pod-info.txt" | tail -n1)"
                        
                        # Get OOMKill events for this pod
                        echo "    OOMKill Events:"
                        grep -A 3 "OOMKill Events:" "$pod_dir/pod-info.txt" | tail -n +2
                    fi
                done
            else
                echo "    No AVS pods"
      fi
    done

        echo -e "\n=== Cluster-wide OOMKill Analysis ==="
        {
            echo "Summary of OOMKill Events:"
            
            # Collect OOMKill events with context
            for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
                if [ -f "$OUTPUT_DIR/nodes/$node/node-info.txt" ]; then
                    # Get node-level OOMKills
                    echo -e "\nNode: $node"
                    echo "Instance Type: $(grep "Instance Type:" "$OUTPUT_DIR/nodes/$node/node-info.txt" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
                    echo "Memory: $(grep "Memory:" "$OUTPUT_DIR/nodes/$node/node-info.txt" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
                    
                    # Get system OOM events
                    echo -e "\nSystem OOM Events:"
                    grep -A 3 "System OOM Events:" "$OUTPUT_DIR/nodes/$node/node-info.txt" | tail -n +2
                    
                    # Get pod OOMKills
                    if [ -d "$OUTPUT_DIR/nodes/$node/pods" ]; then
                        for pod_dir in "$OUTPUT_DIR/nodes/$node/pods"/*; do
                            if [ -d "$pod_dir" ] && [ -f "$pod_dir/pod-info.txt" ]; then
                                pod=$(basename "$pod_dir")
                                echo -e "\nPod: $pod"
                                echo "Memory Settings:"
                                echo "  Request: $(grep "Memory Request:" "$pod_dir/pod-info.txt" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
                                echo "  Limit: $(grep "Memory Limit:" "$pod_dir/pod-info.txt" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
                                echo "  Current Usage: $(grep -A 1 "Current Memory Usage:" "$pod_dir/pod-info.txt" | tail -n1)"
                                echo "OOMKill Events:"
                                grep -A 3 "OOMKill Events:" "$pod_dir/pod-info.txt" | tail -n +2
                            fi
                        done
                    fi
                fi
            done
        } >> "$CLUSTER_TMP_FILE"
    }

    # Create the cluster analysis request
    {
        echo '{
            "model": "'"$MODEL"'",
            "temperature": 0.3,
            "messages": [
                {
                    "role": "system",
                    "content": "'"$CLUSTER_PROMPT"'"
                },
                {
                    "role": "user",
                    "content": "'"$(cat "$CLUSTER_TMP_FILE" | sed 's/"/\\"/g')"'"
                }
            ]
        }'
    } > "$CLUSTER_REQUEST_FILE"

    # Make the API call for cluster analysis with error handling
    if ! safe_api_call "$CLUSTER_REQUEST_FILE" "$CLUSTER_RESPONSE_FILE" "cluster analysis"; then
        echo "❌ Failed to generate cluster analysis due to API error" >&2
        return 1
    fi

    # Create the final report
    {
        echo "# Aerospike Vector Search Cluster Analysis"
        echo -e "\n## Cluster Overview\n"
        cat "$CLUSTER_RESPONSE_FILE" | jq -r '.choices[0].message.content'
        
        echo -e "\n## Individual Node Reports\n"
        for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
            echo -e "\n### Node: $node\n"
            cat "$OUTPUT_DIR/nodes/$node/analysis.md"
        done
    } > "$MARKDOWN_REPORT"

cp "$MARKDOWN_REPORT" "$TEXT_SUMMARY"

    echo "✅ Cluster analysis complete"
    echo "✅ Final report written to: $MARKDOWN_REPORT"
echo "✅ Text summary written to: $TEXT_SUMMARY"
}

# After individual node analysis, create cluster-wide summary
generate_cluster_summary

echo "🎉 Full bundle inspection and analysis complete!"
