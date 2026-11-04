#!/usr/bin/env bash
# Proves that each assertion in dv/sva/ahb_lite_checks.sv can fail. Each mutant breaks
# one copy of the RTL, runs the Ibex simulation, and passes only if the expected
# assertion fires. The repository itself is not changed.
# Run from the repository root on Linux or WSL. Each mutant rebuilds Ibex, so this is
# slow and is not part of dv/run_regression.sh:
#   bash dv/run_sva_mutants.sh

set -u

PATH="$HOME/.local/bin:$PATH"
ROOT=$(pwd)
TMP=$(mktemp -d /tmp/tangnano_sva_mutants.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0

# Arguments: mutant name, assertion that must fire, file, sed expression.
run_mutant() {
    local name=$1 expected=$2 file=$3 expr=$4
    local dir="$TMP/$name" log="$TMP/$name.log" status

    mkdir -p "$dir"
    cp -r "$ROOT/rtl" "$ROOT/dv" "$ROOT/sw" "$dir/"
    ln -s "$ROOT/third_party" "$dir/third_party"

    sed -i "$expr" "$dir/$file"
    if cmp -s "$ROOT/$file" "$dir/$file"; then
        printf 'FAIL  %-22s the mutation did not change %s\n' "$name" "$file"
        failed=$((failed + 1))
        rm -rf "$dir"
        return
    fi

    (cd "$dir" && OBJ_DIR="$TMP/obj_$name" timeout 900 bash dv/run_ibex_sim.sh) > "$log" 2>&1
    status=$?

    if [ "$status" -ne 0 ] && grep -aq "$expected" "$log"; then
        printf 'PASS  %-22s caught by %s\n' "$name" "$expected"
        passed=$((passed + 1))
    else
        printf 'FAIL  %-22s exit %s, %s did not fire\n' "$name" "$status" "$expected"
        grep -a -m3 -E 'Assertion failed|%Error|^FAIL' "$log" | cut -c1-150
        failed=$((failed + 1))
    fi
    rm -rf "$dir" "$TMP/obj_$name"
}

# A one-cycle ERROR on a mapped slave. On the ROM or the default slave, the memory map
# assertions fire first, so they would hide this rule.
run_mutant error_one_cycle a_error_last_after_first rtl/memory/ahb_sram.sv \
    's/assign hresp     = 1'"'"'b0;/assign hresp     = |wr_strb_q;/'

run_mutant error_no_last_cycle a_error_first_then_last rtl/soc_top.sv \
    's/wire        imem_hresp  = rom_err_first_q || rom_err_second_q;/wire        imem_hresp  = rom_err_first_q;/'

run_mutant error_on_idle a_idle_is_zero_wait_okay rtl/soc_top.sv \
    's/imem_hsel \&\& imem_htrans\[1\] \&\& imem_hwrite \&\& //'

run_mutant rom_write_no_error a_rom_write_gets_error rtl/soc_top.sv \
    's/rom_err_first_q  <= imem_hsel \&\& imem_htrans\[1\] \&\& imem_hwrite \&\& cpu_hready;/rom_err_first_q  <= 1'"'"'b0;/'

run_mutant unmapped_no_error a_unmapped_gets_error rtl/interconnect/ahb_interconnect.sv \
    's/err_first_q  <= s_hready \&\& unmapped;/err_first_q  <= 1'"'"'b0;/'

# Removing the adapter's owner lock changes nothing here, because these runs never
# raise a data request during a stalled fetch. tb_obi_to_ahb tests that lock with random
# traffic, so this mutant breaks the stalled address phase directly.
run_mutant addr_changes_in_stall a_addr_stable_in_wait rtl/interconnect/obi_to_ahb_adapter.sv \
    's/assign hsize  = is_data_write ? write_size : SIZE_WORD;/assign hsize  = addr_stalled_q ? SIZE_BYTE : (is_data_write ? write_size : SIZE_WORD);/'

# Passing data_wdata_i straight through changes nothing here, because Ibex holds it
# during the stall, so this mutant breaks HWDATA directly.
run_mutant wdata_not_held a_wdata_stable_in_wait rtl/interconnect/obi_to_ahb_adapter.sv \
    's/assign hwdata = hwdata_q;/assign hwdata = hready ? hwdata_q : ~hwdata_q;/'

run_mutant htrans_seq a_single_transfers_only rtl/interconnect/obi_to_ahb_adapter.sv \
    's/TRANS_NONSEQ = 2'"'"'b10/TRANS_NONSEQ = 2'"'"'b11/'

run_mutant size_always_word a_size_and_alignment rtl/interconnect/obi_to_ahb_adapter.sv \
    's/assign hsize  = is_data_write ? write_size : SIZE_WORD;/assign hsize  = SIZE_WORD;/'

echo "---"
echo "$passed caught, $failed not caught"
[ "$failed" -eq 0 ]
