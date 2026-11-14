#!/usr/bin/env bash
# Runs every self-checking testbench and prints one line per test.
# Run from the repository root:
#   bash dv/run_regression.sh
# The Icarus tests need iverilog and vvp. The Ibex test needs Verilator and
# riscv64-unknown-elf-gcc, on Linux or WSL. A missing tool skips its tests.
# Exits with 1 if any test fails or if no test could run.

set -u

PATH="$HOME/.local/bin:$PATH"
PERIPHERALS="rtl/peripherals/apb_gpio.sv rtl/peripherals/apb_spi.sv rtl/peripherals/apb_uart.sv"
SOC="rtl/soc_pkg.sv rtl/soc_top.sv rtl/memory/ahb_rom.sv rtl/memory/ahb_sram.sv rtl/interconnect/ahb_interconnect.sv rtl/interconnect/ahb_to_apb_bridge.sv $PERIPHERALS"

passed=0
failed=0
skipped=0

mkdir -p work

# The firmware and the RTL must agree on every base address. This needs no simulator.
map_bad=""
for name in ROM SRAM UART SPI GPIO TIMER SYSCTRL; do
    pkg=$(grep -E "localparam logic \[31:0\] ${name}_BASE " rtl/soc_pkg.sv |
          sed -E "s/.*32'h([0-9A-Fa-f_]+).*/\1/" | tr -d '_' | tr 'a-f' 'A-F')
    hdr=$(grep -E "^#define ${name}_BASE " sw/soc_map.h | awk '{print $3}' |
          sed 's/^0x//' | tr 'a-f' 'A-F')
    if [ -z "$pkg" ] || [ "$pkg" != "$hdr" ]; then
        map_bad="$map_bad ${name}(rtl=${pkg:-none},sw=${hdr:-none})"
    fi
done
if [ -z "$map_bad" ]; then
    printf 'PASS  %-24s %s\n' "memory map rtl == sw" "7 base addresses match"
    passed=$((passed + 1))
else
    printf 'FAIL  %-24s%s\n' "memory map rtl == sw" "$map_bad"
    failed=$((failed + 1))
fi

# Prints PASS only if the run exited cleanly and each expected RESULT line reports
# 0 failures. A missing RESULT line is a failure, because the test may have died early.
report() {
    local name=$1 status=$2 log=$3 expected=$4
    local total clean
    total=$(grep -ac '^RESULT: ' "$log")
    clean=$(grep -acE '^RESULT: [0-9]+ checks, 0 failures' "$log")
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
    run_icarus tb_apb_spi           dv/tb_apb_spi.sv rtl/peripherals/apb_spi.sv
    run_icarus tb_apb_uart          dv/tb_apb_uart.sv rtl/peripherals/apb_uart.sv
    run_icarus tb_apb_pstrb         dv/tb_apb_pstrb.sv $PERIPHERALS
    run_icarus tb_ahb_sram          dv/tb_ahb_sram.sv rtl/memory/ahb_sram.sv
    run_icarus tb_ahb_rom           dv/tb_ahb_rom.sv rtl/memory/ahb_rom.sv
    run_icarus tb_ahb_interconnect  dv/tb_ahb_interconnect.sv rtl/soc_pkg.sv rtl/interconnect/ahb_interconnect.sv
    run_icarus tb_ahb_to_apb_bridge dv/tb_ahb_to_apb_bridge.sv rtl/soc_pkg.sv rtl/interconnect/ahb_to_apb_bridge.sv
    run_icarus tb_obi_to_ahb        dv/tb_obi_to_ahb.sv rtl/interconnect/obi_to_ahb_adapter.sv
    run_icarus tb_soc_sram          dv/tb_soc_sram.sv $SOC
    run_icarus tb_soc_system        dv/tb_soc_system.sv $SOC
    run_icarus tb_fpga_top          dv/tb_fpga_top.sv rtl/fpga/fpga_top.sv rtl/fpga/ahb_selftest_master.sv $SOC
else
    echo "SKIP  Icarus tests             iverilog or vvp not found"
    skipped=$((skipped + 11))
fi

if command -v verilator > /dev/null && command -v riscv64-unknown-elf-gcc > /dev/null; then
    log=work/ibex.log
    bash dv/run_ibex_sim.sh > "$log" 2>&1
    report "Ibex firmware and traps" "$?" "$log" 6

    # An assertion whose condition never happened proves nothing, so every counter
    # printed by dv/sva/ahb_lite_checks.sv must be above zero across the runs.
    unexercised=$(grep -a '^SVA: ' "$log" | tr -d '\r' | tr ' ' '\n' |
        awk -F= '/=/ { sum[$1] += $2 } END { for (k in sum) if (sum[k] == 0) printf "%s ", k }')
    if grep -aq '^SVA: ' "$log" && [ -z "$unexercised" ]; then
        printf 'PASS  %-24s all counters above zero\n' "SVA rules exercised"
        passed=$((passed + 1))
    else
        printf 'FAIL  %-24s not exercised: %s\n' "SVA rules exercised" "${unexercised:-no SVA report}"
        failed=$((failed + 1))
    fi

    # The system testbench under Verilator. Its stimulus is the same as under Icarus, so
    # the two runs should report the same checks.
    if verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --default-language 1800-2017         --top-module tb_soc_system --Mdir work/obj_soc_system -o sim_soc_system         dv/tb_soc_system.sv $SOC > work/tb_soc_system_verilator.log 2>&1; then
        work/obj_soc_system/sim_soc_system >> work/tb_soc_system_verilator.log 2>&1
        report "tb_soc_system (Verilator)" "$?" work/tb_soc_system_verilator.log 1
    else
        printf 'FAIL  %-24s build error, see %s
' "tb_soc_system (Verilator)" work/tb_soc_system_verilator.log
        failed=$((failed + 1))
    fi

    # Random OBI adapter traffic with the AHB protocol assertions, and a copy of the
    # adapter that drops the owner lock, which the assertions must catch.
    if bash dv/run_obi_sva.sh; then
        passed=$((passed + 2))
    else
        failed=$((failed + 2))
    fi

    # APB assertions with real PREADY stalls, and a bridge that moves PADDR during one.
    if bash dv/run_apb_wait.sh; then
        passed=$((passed + 2))
    else
        failed=$((failed + 2))
    fi

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
    skipped=$((skipped + 3))
fi

echo "---"
echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]
