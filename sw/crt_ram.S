/* Startup code for an application that runs from SRAM, loaded by the bootloader.
 * The bootloader jumps to _start with interrupts disabled. mtvec still points at the
 * ROM vector table, so the application installs its own table first: a trap here
 * must not run the ROM firmware's handlers. */

#include "soc_map.h"

    .equ UART_DATA, UART_BASE

    /* Ibex's mtvec base must be 256-byte aligned. 32 entries, 4 bytes each. */
    .section .app_vectors, "ax"
    .option push
    .option norvc
    .balign 256
    .global _app_vectors
_app_vectors:
    .rept 32
    j app_trap
    .endr
    .option pop

    .section .text.start, "ax"
    .global _start
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, _stack_top
    la t0, _app_vectors
    csrw mtvec, t0

    /* .data is already in place, because the image was loaded into SRAM as is.
     * Only .bss needs clearing. */
    la t1, _sbss
    la t2, _ebss
1:
    bgeu t1, t2, 2f
    sw zero, 0(t1)
    addi t1, t1, 4
    j 1b
2:
    call main
3:
    j 3b

    /* Any trap in the application sends '?' and stops, so it is told apart from the
     * ROM firmware's '!'. */
    .section .text, "ax"
app_trap:
    li t0, UART_DATA
    li t1, '?'
    sw t1, 0(t0)
4:
    j 4b
