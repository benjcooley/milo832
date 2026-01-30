#!/bin/bash

# Shader Verification Script
# Verifies that compiled shaders produce identical results between
# the C emulator (golden model) and the VHDL/SystemVerilog SM.
#
# Usage:
#   ./run_shader_verify.sh [shader_name] [test_index]
#   ./run_shader_verify.sh              # Run all tests
#   ./run_shader_verify.sh gradient     # Run all gradient tests
#   ./run_shader_verify.sh gradient 0   # Run specific test

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RTL_DIR="$SCRIPT_DIR/../RTL"
SHADER_TOOLS="$SCRIPT_DIR/../tools/shader"
VERIFY_TESTS="$SHADER_TOOLS/verify_tests"
BUILD_ROOT="/tmp/shader_verify_$$"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
SHADER_FILTER="${1:-}"
TEST_FILTER="${2:-}"

echo "========================================"
echo "Shader Verification Test Suite"
echo "========================================"

# Step 1: Build shader tools
echo -e "\n${YELLOW}Step 1: Building shader tools...${NC}"
cd "$SHADER_TOOLS"
make shader_verify >/dev/null 2>&1

# Step 2: Generate test files
echo -e "${YELLOW}Step 2: Generating test files...${NC}"
mkdir -p "$VERIFY_TESTS"
./shader_verify generate "$VERIFY_TESTS" 2>&1 | grep -v "^Generating"

# Step 3: Setup build environment
echo -e "\n${YELLOW}Step 3: Setting up Verilator build environment...${NC}"
rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT/RTL"
mkdir -p "$BUILD_ROOT/verify_tests"

# Copy RTL
cp -r "$RTL_DIR/"* "$BUILD_ROOT/RTL/"
cp -r "$RTL_DIR/Compute/SFU_Tables" "$BUILD_ROOT/"

# Copy test files
cp "$VERIFY_TESTS"/*.hex "$BUILD_ROOT/verify_tests/" 2>/dev/null || true
cp "$SCRIPT_DIR/TB_SV/test_shader_verify.sv" "$BUILD_ROOT/"

# Verilator flags
FLAGS="--binary -j 8 --Mdir obj_dir -I. -IRTL -IRTL/Core -IRTL/Compute -IRTL/Memory -IRTL/Compute/Arithmetic --trace --max-num-width 1024 -Wno-fatal --timing"

# Core includes
CORE_INCLUDES="RTL/Core/simt_pkg.sv RTL/Compute/sfu_pkg.sv RTL/Core/streaming_multiprocessor.sv RTL/Compute/int_alu.sv RTL/Compute/ALU.sv RTL/Compute/sfu_single_cycle.sv RTL/Memory/operand_collector.sv RTL/Memory/fifo.sv RTL/Memory/mock_memory.sv RTL/Core/shared_memory.sv"

cd "$BUILD_ROOT"

# Available shaders and test counts
SHADERS=("gradient" "math" "sfu")
NUM_TESTS=6

passed=0
failed=0
skipped=0

echo -e "\n${YELLOW}Step 4: Running verification tests...${NC}"

for shader in "${SHADERS[@]}"; do
    # Apply shader filter if specified
    if [ -n "$SHADER_FILTER" ] && [ "$shader" != "$SHADER_FILTER" ]; then
        continue
    fi
    
    echo -e "\n--- Shader: $shader ---"
    
    for ((test_idx=0; test_idx<NUM_TESTS; test_idx++)); do
        # Apply test filter if specified
        if [ -n "$TEST_FILTER" ] && [ "$test_idx" != "$TEST_FILTER" ]; then
            continue
        fi
        
        # Check if test files exist
        if [ ! -f "verify_tests/${shader}_input_${test_idx}.hex" ]; then
            echo "  Test $test_idx: SKIP (no input file)"
            ((skipped++))
            continue
        fi
        
        echo -n "  Test $test_idx: "
        
        # Compile with defines for this specific test
        DEFINES="+define+SHADER_NAME=\"$shader\" +define+TEST_INDEX=$test_idx +define+TEST_DIR=\"verify_tests\""
        
        # Build
        rm -rf obj_dir 2>/dev/null || true
        if ! verilator $FLAGS $DEFINES $CORE_INCLUDES test_shader_verify.sv --top-module test_shader_verify >/dev/null 2>&1; then
            echo -e "${RED}COMPILE FAIL${NC}"
            ((failed++))
            continue
        fi
        
        # Run
        if ! ./obj_dir/Vtest_shader_verify +verilator+seed+0 >/dev/null 2>&1; then
            echo -e "${RED}RUN FAIL${NC}"
            ((failed++))
            continue
        fi
        
        # Check if output file was created
        if [ ! -f "verify_tests/${shader}_vhdl_${test_idx}.hex" ]; then
            echo -e "${RED}NO OUTPUT${NC}"
            ((failed++))
            continue
        fi
        
        # Compare expected vs actual
        expected_file="verify_tests/${shader}_expected_${test_idx}.hex"
        actual_file="verify_tests/${shader}_vhdl_${test_idx}.hex"
        
        if diff -q "$expected_file" "$actual_file" >/dev/null 2>&1; then
            echo -e "${GREEN}PASS${NC}"
            ((passed++))
        else
            echo -e "${RED}FAIL (mismatch)${NC}"
            echo "    Expected: $(cat $expected_file | tr '\n' ' ')"
            echo "    Actual:   $(cat $actual_file | tr '\n' ' ')"
            ((failed++))
        fi
    done
done

# Step 5: Summary
echo -e "\n========================================"
echo "Results Summary"
echo "========================================"
echo -e "Passed:  ${GREEN}$passed${NC}"
echo -e "Failed:  ${RED}$failed${NC}"
echo -e "Skipped: ${YELLOW}$skipped${NC}"

# Cleanup
rm -rf "$BUILD_ROOT"

if [ $failed -gt 0 ]; then
    echo -e "\n${RED}VERIFICATION FAILED${NC}"
    exit 1
else
    echo -e "\n${GREEN}ALL TESTS PASSED${NC}"
    exit 0
fi
