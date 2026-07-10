#include <stdio.h>
#include <libbase/uart.h>
#include <generated/csr.h>

/* External LED on J6 pin 25, wired to the ext_led GPIO output added in
 * tn9k_ibex.py. The CPU drives it directly through the ext_led_out CSR. */

/* Busy-loop delay. The image runs from 8 KB BRAM at 13.5 MHz; this count is
 * tuned by eye for a visible ~0.5 s half-period. Use timer0 via libbase if an
 * exact period is ever needed. */
#define DELAY 400000

int main(void)
{
	uart_init();

	uint32_t on = 0;
	while (1) {
		on ^= 1;
		ext_led_out_write(on);
		puts("Toggling LED...");
		for (volatile uint32_t i = 0; i < DELAY; i++) { }
	}

	return 0;
}
