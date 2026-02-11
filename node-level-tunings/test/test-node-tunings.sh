#!/bin/bash
# Validates that swap node-level tunings from the MachineConfig are applied
# on all worker nodes. Requires KUBECONFIG to be set or passed as $1.
set -euo pipefail

if [[ -n "${1:-}" ]]; then
    export KUBECONFIG="$1"
fi

if [[ -z "${KUBECONFIG:-}" ]]; then
    echo "Usage: $0 <kubeconfig>" >&2
    echo "   or: KUBECONFIG=<path> $0" >&2
    exit 1
fi

PASS=0
FAIL=0
SKIP=0
FAILURES=""

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); FAILURES="${FAILURES}\n  - [$NODE] $1"; }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }

WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')
if [[ -z "$WORKERS" ]]; then
    echo "ERROR: no worker nodes found"
    exit 1
fi

echo "Found worker nodes: $WORKERS"
echo ""

for NODE in $WORKERS; do
    echo "=== Testing node: $NODE ==="

    # Run all checks in a single oc debug invocation to minimize overhead.
    # Each check outputs a labeled line for parsing.
    OUTPUT=$(oc debug "node/$NODE" --quiet -- chroot /host bash -c '
        echo "SWAP_MAX=$(cat /sys/fs/cgroup/system.slice/memory.swap.max 2>/dev/null || echo MISSING)"
        echo "SYS_IO_WEIGHT=$(cat /sys/fs/cgroup/system.slice/io.weight 2>/dev/null || echo MISSING)"
        echo "SYS_CPU_WEIGHT=$(cat /sys/fs/cgroup/system.slice/cpu.weight 2>/dev/null || echo MISSING)"
        echo "KUBE_IO_WEIGHT=$(cat /sys/fs/cgroup/kubepods.slice/io.weight 2>/dev/null || echo MISSING)"
        echo "SCALE_FACTOR=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null || echo MISSING)"
        echo "WATERMARK_SCRIPT=$(test -x /usr/local/bin/kubevirt-tune-watermarks.py && echo EXISTS || echo MISSING)"
        echo "IO_LATENCY_SCRIPT=$(test -x /usr/local/bin/kubevirt-io-latency-setup.py && echo EXISTS || echo MISSING)"
        echo "WATERMARK_SVC=$(systemctl is-active kubevirt-tune-watermarks.service 2>/dev/null || echo inactive)"
        echo "IO_LATENCY_SVC=$(systemctl is-active kubevirt-io-latency-setup.service 2>/dev/null || echo inactive)"
        echo "SWAP_TYPE=$(awk "NR>1{print \$2}" /proc/swaps 2>/dev/null | head -1 || echo NONE)"
        echo "SYS_IO_LATENCY=$(cat /sys/fs/cgroup/system.slice/io.latency 2>/dev/null || echo MISSING)"
        echo "KUBE_IO_LATENCY=$(cat /sys/fs/cgroup/kubepods.slice/io.latency 2>/dev/null || echo MISSING)"
    ' 2>/dev/null)

    get_val() { echo "$OUTPUT" | grep "^$1=" | head -1 | cut -d= -f2-; }

    # 1. system.slice MemorySwapMax=0
    val=$(get_val SWAP_MAX)
    if [[ "$val" == "0" ]]; then
        pass "system.slice memory.swap.max = 0"
    else
        fail "system.slice memory.swap.max = '$val' (expected '0')"
    fi

    # 2. system.slice IOWeight=800
    val=$(get_val SYS_IO_WEIGHT)
    if echo "$val" | grep -q "800"; then
        pass "system.slice io.weight contains 800"
    else
        fail "system.slice io.weight = '$val' (expected 'default 800')"
    fi

    # 3. system.slice CPUWeight=800
    val=$(get_val SYS_CPU_WEIGHT)
    if [[ "$val" == "800" ]]; then
        pass "system.slice cpu.weight = 800"
    else
        fail "system.slice cpu.weight = '$val' (expected '800')"
    fi

    # 4. kubepods.slice IOWeight=100
    val=$(get_val KUBE_IO_WEIGHT)
    if echo "$val" | grep -q "100"; then
        pass "kubepods.slice io.weight contains 100"
    else
        fail "kubepods.slice io.weight = '$val' (expected 'default 100')"
    fi

    # 5. Scripts deployed
    val=$(get_val WATERMARK_SCRIPT)
    if [[ "$val" == "EXISTS" ]]; then
        pass "kubevirt-tune-watermarks.py deployed"
    else
        fail "kubevirt-tune-watermarks.py not found"
    fi

    val=$(get_val IO_LATENCY_SCRIPT)
    if [[ "$val" == "EXISTS" ]]; then
        pass "kubevirt-io-latency-setup.py deployed"
    else
        fail "kubevirt-io-latency-setup.py not found"
    fi

    # 6. Services ran successfully
    val=$(get_val WATERMARK_SVC)
    if [[ "$val" == "active" ]]; then
        pass "kubevirt-tune-watermarks.service active"
    else
        fail "kubevirt-tune-watermarks.service status = '$val' (expected 'active')"
    fi

    val=$(get_val IO_LATENCY_SVC)
    if [[ "$val" == "active" ]]; then
        pass "kubevirt-io-latency-setup.service active"
    else
        fail "kubevirt-io-latency-setup.service status = '$val' (expected 'active')"
    fi

    # 7. watermark_scale_factor was tuned (should be > 10, the kernel default)
    val=$(get_val SCALE_FACTOR)
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val > 10 )); then
        pass "watermark_scale_factor = $val (tuned above default 10)"
    elif [[ "$val" =~ ^[0-9]+$ ]]; then
        fail "watermark_scale_factor = $val (still at default, tuning may have failed)"
    else
        fail "watermark_scale_factor = '$val' (unexpected)"
    fi

    # 8. io.latency (conditional on swap type)
    swap_type=$(get_val SWAP_TYPE)
    sys_latency=$(get_val SYS_IO_LATENCY)
    kube_latency=$(get_val KUBE_IO_LATENCY)

    if [[ "$swap_type" == "partition" ]]; then
        if [[ -n "$sys_latency" ]] && echo "$sys_latency" | grep -q "target="; then
            pass "system.slice io.latency configured ($sys_latency)"
        else
            fail "system.slice io.latency not configured (swap is partition-backed)"
        fi
        if [[ -n "$kube_latency" ]] && echo "$kube_latency" | grep -q "target="; then
            pass "kubepods.slice io.latency configured ($kube_latency)"
        else
            fail "kubepods.slice io.latency not configured (swap is partition-backed)"
        fi
    elif [[ "$swap_type" == "file" ]]; then
        skip "io.latency not checked (file-backed swap — known limitation)"
    else
        skip "io.latency not checked (no swap or unknown type: '$swap_type')"
    fi

    echo ""
done

echo "========================================"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ $FAIL -gt 0 ]]; then
    echo -e "\nFailures:$FAILURES"
    exit 1
else
    echo "All checks passed."
fi