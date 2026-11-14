#!/usr/bin/env bash
# Runs the random adapter test (tb_obi_to_ahb) under Verilator with the AHB protocol
# assertions attached to the adapter's AHB port. Then it runs a copy of the adapter that
# drops the owner lock, and passes only if a_addr_stable_in_wait fires.
# Run from the repository root on Linux or WSL:
#   bash dv/run_obi_sva.sh
# Prints one PASS or FAIL line per check. Exits 1 on any failure.

set -u

PATH="$HOME/.local/bin:$PATH"
TMP=$(mktemp -d /tmp/tangnano_obi_sva.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

build_and_run() {
    # Arguments: adapter file, output name. Prints the log path on stdout.
    local adapter=$1 name=$2
    local dir="$TMP/$name"
    mkdir -p "$dir"
    verilator --binary --timing --assert -Wno-fatal -Wno-lint -Wno-style \
        --default-language 1800-2017 --top-module tb_obi_to_ahb --Mdir "$dir/obj" -o sim \
        rtl/soc_pkg.sv dv/tb_obi_to_ahb.sv "$adapter" dv/sva/ahb_lite_checks.sv dv/sva/obi_adapter_checks_bind.sv \
        > "$dir/build.log" 2>&1 || { echo "build failed: $dir/build.log"; return 1; }
    timeout 1200 "$dir/obj/sim" > "$dir/run.log" 2>&1
    echo "$dir/run.log"
}

log=$(build_and_run rtl/interconnect/obi_to_ahb_adapter.sv clean) ||
    { echo "FAIL  OBI random + SVA         build error"; exit 1; }
result=$(grep -a '^RESULT: ' "$log" | tr -d '\r')
svaline=$(grep -a '^SVA: ' "$log" | tr -d '\r')
if grep -aq 'Assertion' "$log" || ! grep -aqE '^RESULT: [0-9]+ checks, 0 failures' "$log" ||
   [ -z "$svaline" ]; then
    echo "FAIL  OBI random + SVA         $result; $svaline, see $log"
    exit 1
fi
# Every protocol counter must be above zero, or the rule never ran on the random traffic.
# Memory-map counters are left out, because this test's addresses are outside the map.
unexercised=$(echo "$svaline" | tr ' ' '\n' | awk -F= '$1 ~ /^(accepted|addr_wait|data_wait|error|idle)$/ && $2 == 0 { printf "%s ", $1 }')
if [ -n "$unexercised" ]; then
    echo "FAIL  OBI random + SVA         not exercised: $unexercised"
    exit 1
fi
echo "PASS  OBI random + SVA         $result; $svaline"

# A copy of the adapter that never holds the owner while the address waits.
mutant="$TMP/adapter_no_lock.sv"
sed 's/wire owner_data = addr_stalled_q ? owner_data_q : data_req_i;/wire owner_data = data_req_i;/' \
    rtl/interconnect/obi_to_ahb_adapter.sv > "$mutant"
if cmp -s rtl/interconnect/obi_to_ahb_adapter.sv "$mutant"; then
    echo "FAIL  OBI owner-lock mutant    the mutation did not change the adapter"
    exit 1
fi
mlog=$(build_and_run "$mutant" mutant) || { echo "FAIL  OBI owner-lock mutant    build error"; exit 1; }
if grep -aq 'a_addr_stable_in_wait' "$mlog"; then
    echo "PASS  OBI owner-lock mutant    caught by a_addr_stable_in_wait"
else
    echo "FAIL  OBI owner-lock mutant    a_addr_stable_in_wait did not fire, see $mlog"
    exit 1
fi
exit 0
