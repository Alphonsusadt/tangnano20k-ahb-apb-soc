#!/usr/bin/env bash
# Runs every self-checking testbench and prints one line per test.
# Run from the repository root:
#   bash dv/run_regression.sh
# The Icarus tests need iverilog and vvp. The Ibex test needs Verilator and
# riscv64-unknown-elf-gcc, on Linux or WSL. A missing tool skips its tests.
# Exits with 1 if any test fails or if no test could run.

set -u

PATH="$HOME/.local/bin:$PATH"
PERIPHERALS="rtl/peripherals/apb_gpio.v rtl/peripherals/apb_spi.v rtl/peripherals/apb_uart.v"
SOC="rtl/soc_top.sv rtl/memory/ahb_sram.sv rtl/interconnect/ahb_interconnect.sv rtl/interconnect/ahb_to_apb_bridge.sv $PERIPHERALS"

passed=0
failed=0
skipped=0

mkdir -p work

# Prints PASS only if the run exited cleanly and each expected RESULT line reports
# 0 failures. A missing RESULT line is a failure, because the test may have died early.
report() {
    local name=$1 status=$2 log=$3 expected=$4
    local total clean
    total=$(grep -ac '^RESULT: ' "$log")
    clean=$(grep -ac '^RESULT: .*, 0 failures' "$log")
    if [ "$status" -eq 0 ] && [ "$total" -eq "$expected" ] && [ "$clean" -eq "$expected" ]; then
        printf 'PASS  %-24s %s\n' "$name" "$(grep -a '^RESULT: ' "$log" | sed 's/^RESULT: //' | tr -d '\r' | paste -sd ';' -)"
        passed=$((passed + 1))
    else
        printf 'FAIL  %-24s see %s\n' "$name" "$log"
        failed=$((failed + 1))
    fi
}

run_icarus() {
    local name=$1
    shift
    local log="work/$name.log"
    if ! iverilog -g2012 -s "$name" -o "work/$name.vvp" "$@" > "$log" 2>&1; then
        printf 'FAIL  %-24s compile error, see %s\n' "$name" "$log"
        failed=$((failed + 1))
        return
    fi
    vvp "work/$name.vvp" >> "$log" 2>&1
    report "$name" "$?" "$log" 1
}

if command -v iverilog > /dev/null && command -v vvp > /dev/null; then
    run_icarus tb_apb_spi           dv/tb_apb_spi.sv rtl/peripherals/apb_spi.v
    run_icarus tb_apb_uart          dv/tb_apb_uart.sv rtl/peripherals/apb_uart.v
    run_icarus tb_apb_pstrb         dv/tb_apb_pstrb.sv $PERIPHERALS
    run_icarus tb_ahb_sram          dv/tb_ahb_sram.sv rtl/memory/ahb_sram.sv
    run_icarus tb_ahb_interconnect  dv/tb_ahb_interconnect.sv rtl/interconnect/ahb_interconnect.sv
    run_icarus tb_ahb_to_apb_bridge dv/tb_ahb_to_apb_bridge.sv rtl/interconnect/ahb_to_apb_bridge.sv
    run_icarus tb_obi_to_ahb        dv/tb_obi_to_ahb.sv rtl/interconnect/obi_to_ahb_adapter.sv
    run_icarus tb_soc_sram          dv/tb_soc_sram.sv $SOC
    run_icarus tb_soc_system        dv/tb_soc_system.sv $SOC
    run_icarus tb_fpga_top          dv/tb_fpga_top.sv rtl/fpga/fpga_top.sv rtl/fpga/ahb_selftest_master.sv $SOC
else
    echo "SKIP  Icarus tests             iverilog or vvp not found"
    skipped=$((skipped + 10))
fi

if command -v verilator > /dev/null && command -v riscv64-unknown-elf-gcc > /dev/null; then
    log=work/ibex.log
    bash dv/run_ibex_sim.sh > "$log" 2>&1
    report "Ibex firmware and trap" "$?" "$log" 2

    # The checked-in image must match the source, or the bitstream runs old firmware.
    make -C sw firmware_check.hex NAME=firmware_check > /dev/null 2>&1
    if cmp -s sw/firmware_check.hex sw/firmware.hex; then
        printf 'PASS  %-24s matches the firmware source\n' "sw/firmware.hex"
        passed=$((passed + 1))
    else
        printf 'FAIL  %-24s out of date, run: make -C sw\n' "sw/firmware.hex"
        failed=$((failed + 1))
    fi
    make -C sw clean NAME=firmware_check > /dev/null 2>&1
else
    echo "SKIP  Ibex tests               verilator or riscv64-unknown-elf-gcc not found"
    skipped=$((skipped + 2))
fi

echo "---"
echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]
