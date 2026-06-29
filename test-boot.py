#!/usr/bin/env python3
"""Boot capture for the Tang Nano 9K Ibex SoC.

Opens the UART with default DTR/RTS (which pulses the FPGA's reconfigure line and
reboots it from flash), also forces a reconfigure with `openFPGALoader -r`,
captures the banner, then pokes the REPL with a newline and `help` to confirm it
is interactive.

Note: the DTR/RTS reset path is flaky for automation (it often reads back all
nulls; only ~1 in 6 tries lands the banner). A null read means the capture failed,
not the boot. The reliable method is a litex_term pty capture plus a physical
reset-button press. Baud must match the SoC (built with --uart-baudrate 9600);
reading at the wrong baud yields all-null framing errors.

Usage: python3 test-boot.py [label]
"""
import subprocess
import sys
import threading
import time

import serial

PORT = "/dev/ttyUSB1"
BAUD = 9600
LABEL = sys.argv[1] if len(sys.argv) > 1 else "test"

# Open with default control-line handling, exactly like litex_term: pyserial
# asserts DTR/RTS on open, which pulses the FPGA's reconfigure line and reboots
# it from flash. (Holding the lines low instead keeps it in reset -> garbage.)
ser = serial.Serial(PORT, BAUD, timeout=0.2)

captured = bytearray()
stop = threading.Event()


def reader():
    while not stop.is_set():
        data = ser.read(4096)
        if data:
            captured.extend(data)


t = threading.Thread(target=reader, daemon=True)
t.start()

print(f"[{LABEL}] reconfiguring FPGA from flash (openFPGALoader -r)...")
r = subprocess.run(
    ["openFPGALoader", "-b", "tangnano9k", "-r"],
    capture_output=True, text=True,
)
sys.stderr.write(r.stderr[-400:] if r.stderr else "")

# Let the BIOS boot and print its banner.
time.sleep(6)

# Exercise the REPL: blank line should give a prompt, `help` should list cmds.
ser.write(b"\r\n")
time.sleep(0.5)
ser.write(b"help\r\n")
time.sleep(2)

stop.set()
t.join(timeout=1)
ser.close()

text = captured.decode("utf-8", errors="replace")
printable = sum(1 for c in captured if 9 <= c <= 126)
total = len(captured) or 1
print(f"[{LABEL}] captured {total} bytes, {100*printable/total:.0f}% printable-ASCII")
print("=" * 60)
print(text)
print("=" * 60)
