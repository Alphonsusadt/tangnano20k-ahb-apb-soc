/* ==============================================================================
 * Linker Script for Tang Nano 20K lowRISC Ibex SoC
 * Target: RISC-V RV32I / RV32IMC (Bare-metal)
 * ============================================================================== */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    /* Instruction ROM / Flash Bootloader (32 KB) */
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K

    /* Data SRAM (32 KB) */
    RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 32K
}

SECTIONS
{
    /* Code and read-only data stored in ROM */
    .text :
    {
        . = ALIGN(4);
        KEEP(*(.text.init)) /* Reset Vector / _start entry point */
        *(.text)
        *(.text.*)
        . = ALIGN(4);
        _etext = .;
    } > ROM

    .rodata :
    {
        . = ALIGN(4);
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
        . = ALIGN(4);
    } > ROM

    /* Initialized data copied from ROM to RAM at startup */
    _sidata = LOADADDR(.data);

    .data :
    {
        . = ALIGN(4);
        _sdata = .;
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > ROM

    /* Zero-initialized BSS section in RAM */
    .bss :
    {
        . = ALIGN(4);
        _sbss = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    /* Stack located at end of Data RAM */
    .stack (NOLOAD) :
    {
        . = ALIGN(8);
        _stack_bottom = .;
        . = . + 2K; /* 2 KB stack size */
        . = ALIGN(8);
        _stack_top = .;
    } > RAM

    /* Global pointer and heap symbols */
    __global_pointer$ = MIN(_sdata + 0x800, MAX(_sdata + 0x800, _ebss - 0x800));
    _end = .;
    PROVIDE(end = .);
}
