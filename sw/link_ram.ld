/* ==============================================================================
 * Linker script for an application loaded into SRAM by the bootloader.
 * The whole image (code, read-only data, initialised data) is one contiguous block
 * at 0x2000_0000, sent as is: there is no copy from ROM. .bss and the stack follow
 * it. The top 4 KB of SRAM belong to the bootloader and are not used here; see
 * docs/memory_map.md, "Tata letak SRAM".
 * ============================================================================== */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    APP (rwx) : ORIGIN = 0x20000000, LENGTH = 28K
}

SECTIONS
{
    .text :
    {
        KEEP(*(.app_vectors))   /* 256-byte aligned, because mtvec needs it */
        KEEP(*(.text.start))    /* _start, the entry address */
        *(.text)
        *(.text.*)
        . = ALIGN(4);
    } > APP

    .rodata :
    {
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
        . = ALIGN(4);
    } > APP

    .data :
    {
        _sdata = .;
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > APP

    /* Not part of the loaded image: crt_ram.S clears it. */
    .bss (NOLOAD) :
    {
        _sbss = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > APP

    _stack_top = ORIGIN(APP) + LENGTH(APP);
    _app_end = _ebss;
    ASSERT(_ebss + 1K <= _stack_top, "application leaves less than 1 KB of stack")

    __global_pointer$ = MIN(_sdata + 0x800, MAX(_sdata + 0x800, _ebss - 0x800));
}
