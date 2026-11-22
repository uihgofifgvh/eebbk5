import struct, zlib, re

path = r"C:\Users\dcj\Desktop\new-boot.img"
data = open(path, "rb").read()
(kernel_size, kernel_addr, ramdisk_size, ramdisk_addr, second_size, second_addr,
 tags_addr, page_size, header_version, os_version) = struct.unpack_from("<10I", data, 8)
koff = page_size
kernel = data[koff:koff + kernel_size]

d = zlib.decompressobj(31)
img = d.decompress(kernel) + d.flush()
trailer = d.unused_data

print("kernel blob:", len(kernel), "gzip payload:", len(kernel) - len(trailer),
      "trailer:", len(trailer))

magic, totalsize = struct.unpack_from(">II", trailer, 0)
print("first dtb magic:", hex(magic), "totalsize:", totalsize)

cnt = trailer.count(b"\xd0\x0d\xfe\xed")
print("d00dfeed occurrences in trailer:", cnt)

zeros = trailer.count(b"\x00")
print("zero bytes in trailer:", zeros, f"({zeros/len(trailer)*100:.1f}%)")

# where do non-zero bytes end?
last = len(trailer.rstrip(b"\x00"))
print("trailer length without trailing zero padding:", last)

# sample: count d00dfeed positions
pos, positions = 0, []
while True:
    i = trailer.find(b"\xd0\x0d\xfe\xed", pos)
    if i < 0:
        break
    positions.append(i)
    pos = i + 4
print("dtb offsets (first 10):", positions[:10])

# kernel strings / symbols
syms = [b"ksu_handle_execveat_sucompat", b"ksu_handle_execveat_ksud",
        b"ksu_handle_execve_sucompat", b"ksu_handle_faccessat",
        b"ksu_handle_stat", b"ksu_handle_devpts", b"ksu_input_hook",
        b"ksu_execveat_hook", b"ksu_vfs_read_hook", b"ksu_handle_execveat",
        b"ksu_handle_setuid", b"ksu_handle_prctl", b"ksu_handle_sys_reboot",
        b"ksu_handle_vfs_read", b"ksu_handle_input_handle_event"]
print("\n--- KSU symbols ---")
for s in syms:
    print(f"{s.decode():35s} {img.count(s)}")

for pat in [b"0.9.5", b"KernelSU version", b"kernelsu version"]:
    print(pat, img.count(pat))

m = re.search(rb"Linux version [^\x00]{0,200}", img)
print("\nbanner:", m.group(0).decode("utf-8", "replace") if m else None)

# look for module vermagic / localversion
for pat in [b"4.4.302-perf", b"4.4.302"]:
    print(pat, img.count(pat))
