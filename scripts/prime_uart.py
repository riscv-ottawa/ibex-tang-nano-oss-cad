#!/usr/bin/env python3
# Condition the FTDI UART channel before litex_term opens it.
#
# On a cold power-on the on-board FT2232 UART (interface B) doesn't start
# forwarding until a program opens it and drives the modem-control lines. The
# first `litex_term` after power-on can come up blank; opening the port once
# with picocom first "wakes" it and a second `litex_term` then works. This does
# the same thing picocom does: open the port, pulse DTR/RTS low->high, flush any
# stale input, and close, so the very first `make serial` behaves like the
# working second run.
import sys
import time

import serial

port = sys.argv[1]
baud = int(sys.argv[2])

p = serial.Serial(port, baud)
p.dtr = p.rts = False
time.sleep(0.15)
p.dtr = p.rts = True
time.sleep(0.15)
p.reset_input_buffer()
p.close()
