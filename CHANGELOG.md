# Changelog

## [Critical Fix] Multi-Warp Deadlock Resolution

**Date:** January 26, 2026

### 1. Root Cause: Selection Mismatch in Operand Collector

The deadlock causing **Warp 14** (and potentially others) to hang was traced to a timing race and logical discrepancy within the `Operand Collector (OC)` module.

- **Combinational Search vs. Sequential Release**: The OC uses a combinational block (`always_comb`) to search for instructions ready to dispatch, while an `always_ff` block updates their state to `IDLE` (the "release" step) after pipeline acceptance.
- **The Conflict**: Previously, the `always_ff` block was **re-evaluating** the search logic independently instead of using the stable results from the `always_comb` block.
- **Missing Strict Check**: The sequential release logic lacked the "Strict Check" for ALU/CTRL structural hazards. In dual-issue cycles where Port 0 selected an ALU/CTRL instruction and Port 1 attempted conflicting access, the combinational logic correctly blocked Port 1. However, the sequential logic—using looser rules—mistakenly identified the blocked instruction as "released."
- **Ghost Release**: This resulted in a **"Ghost Release"**, where an instruction (e.g., Warp 14's loop counter increment) was cleared from the collector but **never entered the execution pipeline**. Consequently, it never performed a writeback, leaving its destination register permanently marked "busy" in the scoreboard, deadlocking the warp.

### 2. The Fix

The `RTL/Memory/operand_collector.sv` module was refactored to ensure absolute consistency between dispatch and release:

- **State Capture**: Added internal signals (`p0_idx_sel`, `p1_idx_sel`) to capture the exact indices of units selected during the combinational phase.
- **Consistent Release**: Updated the sequential `RELEASE` logic to use these captured indices directly, bypassing independent re-evaluation and eliminating the mismatch possibility.
- **Correct Indexing**: Synchronized the round-robin pointer and sequence ID updates to properly handle simultaneous dual-issue releases for the same warp.

### 3. Verification Results

The rigorous `test_multi_warp_torus` benchmark now completes successfully:

- **Total Cycles**: 7415
- **Status**: SUCCESS (Animation verified)
- **Warp 14**: Successfully completes execution loops without stalling.

Diagnostic traces used to identify this issue have been removed to return the codebase to a clean, production-ready state.
