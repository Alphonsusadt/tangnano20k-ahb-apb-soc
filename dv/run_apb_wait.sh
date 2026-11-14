#!/usr/bin/env bash
# Runs the APB assertions with real PREADY stalls, which the Ibex runs never produce.
# Run from the repository root on Linux or WSL:
#   bash dv/run_apb_wait.sh
# Prints one PASS or FAIL line. Exits 1 on failure, or if the stalls never happened,
# because a rule that never sees a wait proves nothing about waits.

set -u

PATH="$HOME/.local/bin:$PATH"
ROOT=$(pwd)
TMP=$(mktemp -d /tmp/tangnano_apb_wait.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

SOURCES="dv/tb_apb_wait.sv rtl/interconnect/ahb_to_apb_bridge.sv dv/sva/apb_checks.sv"

build_and_run() {
    # Arguments: bridge file, output name. Prints the log path on stdout.
    local bridge=$1 name=$2
    local dir="$TMP/$name"
    mkdir -p "$dir"
    verilator --binary --timing --assert -Wno-fatal -Wno-lint -Wno-style \
        --default-language 1800-2017 --top-module tb_apb_wait --Mdir "$dir/obj" -o sim \
        rtl/soc_pkg.sv dv/tb_apb_wait.sv "$bridge" dv/sva/apb_checks.sv > "$dir/build.log" 2>&1 || {
            echo "build failed: $dir/build.log"; return 1; }
    "$dir/obj/sim" > "$dir/run.log" 2>&1
    echo "$dir/run.log"
}

# The clean bridge: every check must pass, and stalls must have happened.
log=$(build_and_run rtl/interconnect/ahb_to_apb_bridge.sv clean) || { echo "FAIL  APB waits                build error"; exit 1; }
result=$(grep -a '^RESULT: ' "$log" | tr -d '\r')
waits=$(grep -a '^APB: ' "$log" | tr -d '\r' | sed 's/.*wait_cycles=\([0-9]*\).*/\1/')
if grep -aq 'Assertion' "$log" || ! grep -aqE '^RESULT: [0-9]+ checks, 0 failures' "$log" ||
   [ -z "$waits" ] || [ "$waits" -eq 0 ]; then
    echo "FAIL  APB waits                $result, wait_cycles=${waits:-none}, see $log"
    exit 1
fi
echo "PASS  APB waits                $result; wait_cycles=$waits"

# A bridge that moves PADDR during a stall. The stability rule must fire.
mutant="$TMP/bridge_moves.sv"
sed "s/ST_ACCESS: if (selected_pready) begin/ST_ACCESS: if (!selected_pready) paddr <= paddr ^ 32'h4; else if (selected_pready) begin/" \
    rtl/interconnect/ahb_to_apb_bridge.sv > "$mutant"
if cmp -s rtl/interconnect/ahb_to_apb_bridge.sv "$mutant"; then
    echo "FAIL  APB stall mutant         the mutation did not change the bridge"
    exit 1
fi
mlog=$(build_and_run "$mutant" mutant) || { echo "FAIL  APB stall mutant         build error"; exit 1; }
if grep -aq 'a_apb_stable_until_done' "$mlog"; then
    echo "PASS  APB stall mutant         caught by a_apb_stable_until_done"
else
    echo "FAIL  APB stall mutant         a_apb_stable_until_done did not fire, see $mlog"
    exit 1
fi
exit 0
