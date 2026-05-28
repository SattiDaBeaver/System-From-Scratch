# software/uart_loader.py

import serial
import struct
import sys
import os
import argparse
import time


# ──────────────────────────────────────
#  Config
# ──────────────────────────────────────
BAUD_RATE   = 115200
READY_BYTE  = 0xAA
OK_BYTE     = 0xBB
ERROR_BYTE  = 0xEE
TIMEOUT     = 10  # seconds


# ──────────────────────────────────────
#  Helpers
# ──────────────────────────────────────

def pad_to_word(data: bytes) -> bytes:
    """Pad binary to multiple of 4 bytes"""
    remainder = len(data) % 4
    if remainder:
        data += b'\x00' * (4 - remainder)
    return data


def checksum(data: bytes) -> int:
    """XOR checksum over all bytes"""
    result = 0
    for b in data:
        result ^= b
    return result & 0xFF


def send_word(ser: serial.Serial, word: int):
    """Send a 32-bit word little endian"""
    ser.write(struct.pack('<I', word))


# ──────────────────────────────────────
#  Main
# ──────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="RISC-V UART Bootloader")
    parser.add_argument("binary",          help="Path to .bin file")
    parser.add_argument("--port", "-p",    required=True, help="Serial port (e.g. COM3 or /dev/ttyUSB0)")
    parser.add_argument("--baud", "-b",    type=int, default=BAUD_RATE, help="Baud rate (default 115200)")
    parser.add_argument("--timeout", "-t", type=int, default=TIMEOUT,   help="Timeout in seconds")
    args = parser.parse_args()

    # Load binary
    if not os.path.exists(args.binary):
        print(f"[ERROR] File not found: {args.binary}")
        sys.exit(1)

    with open(args.binary, 'rb') as f:
        data = f.read()

    data = pad_to_word(data)
    size = len(data)
    chk  = checksum(data)

    print(f"[INFO] Binary: {args.binary}")
    print(f"[INFO] Size:   {size} bytes ({size // 4} words)")
    print(f"[INFO] Checksum: 0x{chk:08x}")

    # Open serial port
    try:
        ser = serial.Serial(args.port, args.baud, timeout=args.timeout)
    except serial.SerialException as e:
        print(f"[ERROR] Could not open port {args.port}: {e}")
        sys.exit(1)

    print(f"[INFO] Opened {args.port} at {args.baud} baud")
    print(f"[INFO] Waiting for FPGA ready signal (0xAA)...")

    # Wait for ready byte
    start = time.time()
    while True:
        if time.time() - start > args.timeout:
            print("[ERROR] Timeout waiting for ready byte")
            ser.close()
            sys.exit(1)

        byte = ser.read(1)
        if not byte:
            continue
        if byte[0] == READY_BYTE:
            print("[INFO] FPGA ready!")
            break
        else:
            print(f"[WARN] Unexpected byte: 0x{byte[0]:02x}")

    # Send size (4 bytes, little endian)
    print(f"[INFO] Sending size: {size} bytes")
    ser.write(struct.pack('<I', size))

    # Send binary
    print(f"[INFO] Sending binary...")
    chunk_size = 256
    sent = 0
    while sent < size:
        chunk = data[sent:sent + chunk_size]
        ser.write(chunk)
        sent += len(chunk)
        percent = (sent / size) * 100
        print(f"\r[INFO] Progress: {sent}/{size} bytes ({percent:.1f}%)", end='', flush=True)
    print()

    # Send checksum
    print(f"[INFO] Sending checksum: 0x{chk:02x}")
    ser.write(bytes([chk]))

    # Wait for response
    print("[INFO] Waiting for response...")
    response = ser.read(1)
    if not response:
        print("[ERROR] Timeout waiting for response")
        ser.close()
        sys.exit(1)

    if response[0] == OK_BYTE:
        print("[OK] Program loaded successfully, CPU is running!")
    elif response[0] == ERROR_BYTE:
        print("[ERROR] Checksum mismatch, program not loaded")
        ser.close()
        sys.exit(1)
    else:
        print(f"[ERROR] Unexpected response: 0x{response[0]:02x}")
        ser.close()
        sys.exit(1)

    ser.close()


if __name__ == "__main__":
    main()