import sys
import struct

def bin2mif(input_file, output_file, depth=4096, width=32):
    with open(input_file, 'rb') as f:
        data = f.read()

    # Pad to word boundary
    while len(data) % 4:
        data += b'\x00'

    words = []
    for i in range(0, len(data), 4):
        word = struct.unpack_from('<I', data, i)[0]
        words.append(word)

    with open(output_file, 'w') as f:
        f.write(f"DEPTH = {depth};\n")
        f.write(f"WIDTH = {width};\n")
        f.write("ADDRESS_RADIX = HEX;\n")
        f.write("DATA_RADIX = HEX;\n")
        f.write("CONTENT BEGIN\n")
        for i, word in enumerate(words):
            f.write(f"    {i:04X} : {word:08X};\n")
        # Fill rest with zeros
        for i in range(len(words), depth):
            f.write(f"    {i:04X} : 00000000;\n")
        f.write("END;\n")

if __name__ == "__main__":
    bin2mif(sys.argv[1], sys.argv[2])