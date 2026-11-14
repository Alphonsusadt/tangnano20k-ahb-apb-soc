/* ==============================================================================
 * SoC memory map for the firmware, matching rtl/soc_pkg.sv and docs/memory_map.md.
 * Plain numbers without a U suffix, so crt0.S can include this file too.
 * dv/run_regression.sh checks that every base here equals the one in soc_pkg.sv.
 * sw/link.ld repeats ROM_BASE and SRAM_BASE, because a linker script cannot
 * include a C header.
 * ============================================================================== */

#ifndef SOC_MAP_H
#define SOC_MAP_H

#define ROM_BASE        0x00000000
#define SRAM_BASE       0x20000000
#define UART_BASE       0x40000000
#define SPI_BASE        0x40001000
#define GPIO_BASE       0x40002000
#define TIMER_BASE      0x40003000
#define SYSCTRL_BASE    0x40004000

/* Inside no block, so the interconnect's default slave answers ERROR. */
#define UNMAPPED_ADDR   0x60000000

#endif
