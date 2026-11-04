/* Startup code for Ibex: the vector table, the reset entry, and C runtime setup. */

    .equ UART_DATA, 0x40000000

    /* Ibex takes exceptions at boot_addr, interrupts at boot_addr + 4 * cause,
     * and resets at boot_addr + 0x80.
     * Each entry must stay 4 bytes, so compressed instructions are off here. */
    .section .vectors, "ax"
    .option push
    .option norvc
    .global _vectors
_vectors:
    .rept 32
    j trap_handler
    .endr
reset_entry:
    j _start
    .option pop

    .section .text.init, "ax"
    .global _start
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, _stack_top

    /* Copy .data from ROM to RAM. */
    la t0, _sidata
    la t1, _sdata
    la t2, _edata
1:
    bgeu t1, t2, 2f
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j 1b
2:
    /* Clear .bss. */
    la t1, _sbss
    la t2, _ebss
3:
    bgeu t1, t2, 4f
    sw zero, 0(t1)
    addi t1, t1, 4
    j 3b
4:
    call main
5:
    j 5b

    /* There are no handlers yet, so any trap sends '!' and stops here. */
    .section .text, "ax"
    .global trap_handler
trap_handler:
    li t0, UART_DATA
    li t1, '!'
    sw t1, 0(t0)
6:
    j 6b
