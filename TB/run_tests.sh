#!/bin/bash
#-------------------------------------------------------------------------------
# run_tests.sh
# Modular VHDL Unit Test Runner
#
# Usage: ./run_tests.sh [test_name]
#   No args: run all tests
#   test_name: run specific test (e.g., ./run_tests.sh int_alu)
#
# Requires: GHDL (open source VHDL simulator)
#   Install: brew install ghdl (macOS) or apt install ghdl (Linux)
#-------------------------------------------------------------------------------

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RTL_DIR="$SCRIPT_DIR/../rtl"
TB_DIR="$SCRIPT_DIR"
WORK_DIR="$SCRIPT_DIR/work"

# Create work directory
mkdir -p "$WORK_DIR"

# Check for GHDL
if ! command -v ghdl &> /dev/null; then
    echo -e "${RED}Error: GHDL not found. Install with 'brew install ghdl' or 'apt install ghdl'${NC}"
    exit 1
fi

echo "========================================"
echo "Milo832 GPU VHDL Unit Test Suite"
echo "========================================"

# Function to compile a VHDL file
compile_vhd() {
    local file=$1
    echo -n "  Compiling $(basename $file)... "
    if ghdl -a --workdir="$WORK_DIR" --std=08 "$file" 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        ghdl -a --workdir="$WORK_DIR" --std=08 "$file"
        return 1
    fi
}

# Function to run a test
run_test() {
    local tb_name=$1
    local tb_entity="tb_$tb_name"
    
    echo ""
    echo "----------------------------------------"
    echo -e "${YELLOW}Running: $tb_entity${NC}"
    echo "----------------------------------------"
    
    # Elaborate
    if ! ghdl -e --workdir="$WORK_DIR" --std=08 "$tb_entity" 2>/dev/null; then
        echo -e "${RED}Elaboration failed${NC}"
        return 1
    fi
    
    # Run simulation
    local start_time=$(date +%s.%N)
    if ghdl -r --workdir="$WORK_DIR" --std=08 "$tb_entity" --stop-time=100ms 2>&1 | tee "$WORK_DIR/${tb_entity}.log"; then
        local end_time=$(date +%s.%N)
        local elapsed=$(echo "$end_time - $start_time" | bc)
        
        # Check for failures in log
        if grep -q "FAIL:" "$WORK_DIR/${tb_entity}.log"; then
            echo -e "${RED}FAILED${NC} (${elapsed}s)"
            return 1
        else
            echo -e "${GREEN}PASSED${NC} (${elapsed}s)"
            return 0
        fi
    else
        echo -e "${RED}Simulation error${NC}"
        return 1
    fi
}

# Compile RTL files in dependency order
echo ""
echo "Compiling RTL sources..."

# Track compiled files to avoid duplicates
COMPILED=""

is_compiled() {
    echo "$COMPILED" | grep -q ":$1:"
}

mark_compiled() {
    COMPILED="$COMPILED:$1:"
}

# Core packages first
compile_vhd "$RTL_DIR/core/simt_pkg.vhd" || exit 1
mark_compiled "simt_pkg.vhd"

# Compute packages
if [ -f "$RTL_DIR/compute/sfu_pkg.vhd" ]; then
    compile_vhd "$RTL_DIR/compute/sfu_pkg.vhd"
    mark_compiled "sfu_pkg.vhd"
fi

# Memory modules
for f in "$RTL_DIR/memory/"*.vhd; do
    fname=$(basename "$f")
    if [ -f "$f" ] && ! is_compiled "$fname"; then
        compile_vhd "$f"
        mark_compiled "$fname"
    fi
done

# Compute modules
for f in "$RTL_DIR/compute/"*.vhd; do
    fname=$(basename "$f")
    if [ -f "$f" ] && ! is_compiled "$fname"; then
        compile_vhd "$f"
        mark_compiled "$fname"
    fi
done

# Core modules (skip already compiled packages, defer gpu_core.vhd)
for f in "$RTL_DIR/core/"*.vhd; do
    fname=$(basename "$f")
    # Skip gpu_core.vhd - it depends on graphics modules
    if [ "$fname" = "gpu_core.vhd" ]; then
        continue
    fi
    if [ -f "$f" ] && ! is_compiled "$fname"; then
        compile_vhd "$f"
        mark_compiled "$fname"
    fi
done

# Graphics modules
for f in "$RTL_DIR/graphics/"*.vhd; do
    fname=$(basename "$f")
    if [ -f "$f" ] && ! is_compiled "$fname"; then
        compile_vhd "$f"
        mark_compiled "$fname"
    fi
done

# Top-level modules that depend on both core and graphics
if [ -f "$RTL_DIR/core/gpu_core.vhd" ] && ! is_compiled "gpu_core.vhd"; then
    compile_vhd "$RTL_DIR/core/gpu_core.vhd"
    mark_compiled "gpu_core.vhd"
fi

# Bus modules (packages first)
if [ -d "$RTL_DIR/bus" ]; then
    if [ -f "$RTL_DIR/bus/system_bus_pkg.vhd" ]; then
        compile_vhd "$RTL_DIR/bus/system_bus_pkg.vhd"
        mark_compiled "system_bus_pkg.vhd"
    fi
    for f in "$RTL_DIR/bus/"*.vhd; do
        fname=$(basename "$f")
        if [ -f "$f" ] && ! is_compiled "$fname"; then
            compile_vhd "$f"
            mark_compiled "$fname"
        fi
    done
fi

# Compile testbenches
echo ""
echo "Compiling testbenches..."
for f in "$TB_DIR/"tb_*.vhd; do
    [ -f "$f" ] && compile_vhd "$f"
done

# Define test list
TESTS=(
    "int_alu"
    "fifo"
    "fpu"
    "shared_memory"
    "rop"
    "tile_rasterizer"
    "gpu_core"
    "texture_stress"
    "render_scene"
)

# Track results
PASSED=0
FAILED=0
SKIPPED=0

# Run tests
if [ $# -eq 0 ]; then
    # Run all tests
    echo ""
    echo "========================================"
    echo "Running all unit tests..."
    echo "========================================"
    
    for test in "${TESTS[@]}"; do
        if [ -f "$TB_DIR/tb_${test}.vhd" ]; then
            if run_test "$test"; then
                ((PASSED++))
            else
                ((FAILED++))
            fi
        else
            echo -e "${YELLOW}Skipped: tb_${test} (not found)${NC}"
            ((SKIPPED++))
        fi
    done
else
    # Run specific test
    test=$1
    if [ -f "$TB_DIR/tb_${test}.vhd" ]; then
        if run_test "$test"; then
            ((PASSED++))
        else
            ((FAILED++))
        fi
    else
        echo -e "${RED}Test not found: tb_${test}.vhd${NC}"
        exit 1
    fi
fi

# Summary
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Passed:  ${GREEN}$PASSED${NC}"
echo -e "Failed:  ${RED}$FAILED${NC}"
echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
