// CRC-32C (Castagnoli), the frame and header checksum of log.md par. 4.
// core:hash carries only the IEEE polynomial, so the table lives here,
// beside the framing code that is its only consumer (RECORD-T-0001).
// The CRC catches accidental corruption cheaply and locally — a torn
// write, a bad sector; deliberate alteration is the hash chain's job,
// and the two are not interchangeable (log.md par. 4).
package record

// The reflected Castagnoli polynomial. The check value for the ASCII
// bytes "123456789" is 0xE3069283, asserted by the tests against the
// published vector.
@(private)
CRC32C_POLY :: u32(0x82F6_3B78)

@(private)
crc32c_table: [256]u32

@(init)
@(private)
crc32c_table_init :: proc "contextless" () {
	for i in 0 ..< 256 {
		c := u32(i)
		for _ in 0 ..< 8 {
			if c & 1 == 1 {
				c = (c >> 1) ~ CRC32C_POLY
			} else {
				c >>= 1
			}
		}
		crc32c_table[i] = c
	}
}

// crc32c is the CRC-32C over the given chunks in order, as if they
// were one contiguous buffer — the frame checksum covers the length
// prefix followed by the body without concatenating them.
@(private)
crc32c :: proc(chunks: ..[]byte) -> u32 {
	crc := u32(0xFFFF_FFFF)
	for chunk in chunks {
		for b in chunk {
			crc = crc32c_table[(crc ~ u32(b)) & 0xFF] ~ (crc >> 8)
		}
	}
	return crc ~ 0xFFFF_FFFF
}
