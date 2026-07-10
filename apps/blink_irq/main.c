#include <stdio.h>
#include <libbase/uart.h>
#include <irq.h>
#include <generated/csr.h>
#include <generated/soc.h>

/* Same behaviour as the blink app (toggle the external LED on J6 pin 25 and
 * print each time), but driven by timer0's periodic interrupt instead of a
 * busy-loop. timer0 counts down from PERIOD, raises an event at zero, reloads,
 * and repeats; the event is wired to a fast local interrupt on the Ibex. */

#define PERIOD (CONFIG_CLOCK_FREQUENCY / 2)   /* ~0.5 s half-period */

static volatile uint32_t ticks;

void isr(void);   /* called from trap_entry in crt0.S */

/* Called from trap_entry (crt0.S) on every trap. Dispatch on the LiteX pending
 * mask. uart_init() leaves the UART interrupt unmasked, and libbase's uart.c is
 * the interrupt-driven build, so the UART must be serviced here too: without it,
 * a received byte would re-fire forever (the pending event is never cleared) and
 * buffered TX output would never drain. Keep the timer work minimal: clear the
 * event, toggle the LED, and let main() do the (slow) serial printing. */
void isr(void)
{
	unsigned int irqs = irq_pending() & irq_getmask();

#ifdef CSR_UART_BASE
	if (irqs & (1 << UART_INTERRUPT))
		uart_isr();
#endif

	if (irqs & (1 << TIMER0_INTERRUPT)) {
		timer0_ev_pending_write(1);        /* write-1-to-clear the event */
		ticks++;
		ext_led_out_write(ticks & 1);      /* toggle the external LED */
	}
}

static void timer0_periodic(uint32_t period)
{
	timer0_en_write(0);
	timer0_load_write(period);             /* initial countdown */
	timer0_reload_write(period);           /* auto-reload -> periodic */
	timer0_en_write(1);
	timer0_ev_pending_write(1);            /* clear any stale event */
	timer0_ev_enable_write(1);             /* route the event to the IRQ line */
}

int main(void)
{
	uart_init();

	timer0_periodic(PERIOD);
	irq_setmask(irq_getmask() | (1 << TIMER0_INTERRUPT));
	irq_setie(1);                          /* enable interrupts globally */

	/* Print only after interrupts are on. libbase's uart.c is the
	 * interrupt-driven build: writes past the 16-byte TX FIFO go into a
	 * software ring that is drained by uart_isr() (dispatched from isr()).
	 * With interrupts still off that ring never drains, so a line longer than
	 * the FIFO would truncate and corrupt, which is why nothing is written
	 * before irq_setie(1). */
	puts("blink_irq: booted, timer IRQ enabled");

	uint32_t last = 0;
	while (1) {
		if (ticks != last) {           /* a toggle happened in the ISR */
			last = ticks;
			puts("Toggling LED...");
		}
	}

	return 0;
}
