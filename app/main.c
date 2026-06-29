#include <stdio.h>
#include <libbase/uart.h>
#include <libbase/console.h>
#include <generated/csr.h>

int main(void)
{
	uart_init();
	puts("\nIbex on Tang Nano 9K - echo + blink\n");

	uint32_t led = 0;
	while (1) {
		if (readchar_nonblock()) {
			char c = getchar();
			putchar(c);            /* echo the byte back */
			led ^= 1;
			leds_out_write(led);   /* toggle LED on each keypress */
		}
	}

	return 0;
}
