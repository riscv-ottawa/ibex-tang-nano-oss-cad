.global main
.global isr
.global _start

# Startup for an interrupt-driven, serial/flash-booted program.
#
# Like apps/common/crt0.S, the BIOS jumps to the load address, so _start sits at
# offset 0. Unlike it, this app actually takes interrupts, and Ibex takes its
# fast (local) interrupts in VECTORED mode: on interrupt cause C the core jumps
# to mtvec.BASE + 4*C. Ibex also forces mtvec.BASE to 256-byte alignment (it
# masks the low 8 bits). So mtvec must point at a 256-byte-aligned vector table,
# not a bare trap_entry: a non-aligned address gets masked down to the load base
# (0x40000000 == _start), and every interrupt then restarts the program instead
# of dispatching. This mirrors how the LiteX BIOS sets up its own mtvec.
#
# Every table slot funnels into trap_entry, which saves the caller-saved
# registers, calls the C isr(), restores them, and returns with mret. isr()
# dispatches on the LiteX pending-IRQ mask.
#
# The BIOS hands off with mstatus.MIE still set, so we clear it here and let
# main() re-enable interrupts with irq_setie(1) only after the trap handler,
# timer, and IRQ mask are set up. Otherwise a stray interrupt (e.g. a UART RX
# byte, which uart_init() unmasks) could fire before main() is ready.

.section .text
_start:
  csrci mstatus, 8        # clear mstatus.MIE; main() enables IRQs when ready
  la sp, _fstack
  la t0, vector_table
  ori t0, t0, 1           # MODE = 1: vectored (base is already 256-aligned)
  csrw mtvec, t0

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

# Ibex vectored trap table: cause C enters at base + 4*C (exceptions at base+0).
# The base must be 256-byte aligned, and every slot must be a full 4-byte jump
# so the 4*C stride holds, hence .option norvc around the otherwise-compressible
# jumps. All causes share trap_entry; isr() reads the pending mask to find the
# source.
.option push
.option norvc
.balign 256
vector_table:
  .rept 32
  j trap_entry
  .endr
.option pop

.balign 4
trap_entry:
  addi sp, sp, -16*4
  sw ra,  0*4(sp)
  sw t0,  1*4(sp)
  sw t1,  2*4(sp)
  sw t2,  3*4(sp)
  sw a0,  4*4(sp)
  sw a1,  5*4(sp)
  sw a2,  6*4(sp)
  sw a3,  7*4(sp)
  sw a4,  8*4(sp)
  sw a5,  9*4(sp)
  sw a6, 10*4(sp)
  sw a7, 11*4(sp)
  sw t3, 12*4(sp)
  sw t4, 13*4(sp)
  sw t5, 14*4(sp)
  sw t6, 15*4(sp)
  call isr
  lw ra,  0*4(sp)
  lw t0,  1*4(sp)
  lw t1,  2*4(sp)
  lw t2,  3*4(sp)
  lw a0,  4*4(sp)
  lw a1,  5*4(sp)
  lw a2,  6*4(sp)
  lw a3,  7*4(sp)
  lw a4,  8*4(sp)
  lw a5,  9*4(sp)
  lw a6, 10*4(sp)
  lw a7, 11*4(sp)
  lw t3, 12*4(sp)
  lw t4, 13*4(sp)
  lw t5, 14*4(sp)
  lw t6, 15*4(sp)
  addi sp, sp, 16*4
  mret
