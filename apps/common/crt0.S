.global main
.global _start

# Minimal startup for a serial-booted program.
#
# The LiteX BIOS uploads this binary to the kernel address (main_ram base)
# and jumps straight to that address, so the entry point must sit at offset 0.
# That is different from the Ibex main-bitstream boot, whose crt0 puts a
# 256-byte vector table first and the reset entry at offset 0x80 (the Ibex
# hardware reset vector is boot_addr+0x80). Reusing that crt0 here would land
# the CPU in the trap table instead of the reset entry.
#
# The BIOS runs with interrupts enabled and jumps straight here without
# clearing them, so we clear mstatus.MIE first. libbase's interrupt-driven
# uart.c unmasks the UART interrupt in uart_init(); left with MIE set, the
# first UART event would vector into the hang loop above. With MIE off, uart.c
# falls back to pumping uart_isr() by hand, which is all this app needs.

.section .text
_start:
  csrci mstatus, 8        # clear mstatus.MIE: run with interrupts globally off
  la sp, _fstack
  la t0, trap
  csrw mtvec, t0          # direct mode, mode bits clear

data_init:
  la t0, _fdata
  la t1, _edata
  la t2, _fdata_rom
data_loop:
  beq t0, t1, data_done
  lw t3, 0(t2)
  sw t3, 0(t0)
  addi t0, t0, 4
  addi t2, t2, 4
  j data_loop
data_done:

bss_init:
  la t0, _fbss
  la t1, _ebss
bss_loop:
  beq t0, t1, bss_done
  sw zero, 0(t0)
  addi t0, t0, 4
  j bss_loop
bss_done:

  call main

hang:
  j hang

.balign 4
trap:
  j trap
