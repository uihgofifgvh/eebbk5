import struct, zlib, sys, re

path = r"C:\Users\dcj\Desktop\new-boot.img"
data = open(path, "rb").read()
print("file size:", len(data))
if data[:8] != b"ANDROID!":
    print("NOT an Android boot image")
    sys.exit(1)

(kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
 second_size, second_addr, tags_addr, page_size,
 header_version, os_version) = struct.unpack_from("<10I", data, 8)

name = data[48:64].split(b"\0")[0].decode("utf-8", "replace")
cmdline = data[64:576].split(b"\0")[0].decode("utf-8", "replace")
extra = data[608:1632].split(b"\0")[0].decode("utf-8", "replace")

print("header_version:", header_version)
print("page_size:", page_size)
print("kernel_size:", kernel_size, hex(kernel_size))
print("kernel_addr:", hex(kernel_addr))
print("ramdisk_size:", ramdisk_size)
print("ramdisk_addr:", hex(ramdisk_addr))
print("second_size:", second_size)
print("tags_addr:", hex(tags_addr))
print("name:", repr(name))
print("cmdline:", repr(cmdline))
print("extra_cmdline:", repr(extra))

if header_version >= 1 and len(data) >= 1656:
    rec_size, rec_off, hdr_size, dtb_size, dtb_addr = struct.unpack_from("<IQIIQ", data, 1632)
    print("recovery_dtbo_size:", rec_size, "header_size:", hdr_size,
          "dtb_size:", dtb_size, "dtb_addr:", hex(dtb_addr))

koff = page_size
kernel = data[koff:koff + kernel_size]
print("\nkernel blob first 4 bytes:", kernel[:4].hex())

img = None
trailer = b""
if kernel[:2] == b"\x1f\x8b":
    d = zlib.decompressobj(31)
    img = d.decompress(kernel) + d.flush()
    trailer = d.unused_data
    print("gzip kernel: decompressed", len(img), "bytes, trailing", len(trailer), "bytes")
    if trailer[:4] == b"\xd0\x0d\xfe\xed":
        print("trailing blob is a DTB (magic d00dfeed)")
else:
    img = kernel
    print("kernel not gzip (raw Image?)")

if len(data) >= koff + kernel_size + ramdisk_size:
    rd = data[koff + kernel_size: koff + kernel_size + ramdisk_size]
    print("ramdisk magic:", rd[:4].hex(), "(1f8b.. = gzip, 070701 = cpio)")
else:
    print("ramdisk extends past EOF!")

def find_all(hay, needle, limit=5):
    out, start = [], 0
    while len(out) < limit:
        i = hay.find(needle, start)
        if i < 0:
            break
        out.append(i)
        start = i + 1
    return out

print("\n--- kernel strings ---")
i = img.find(b"Linux version")
if i >= 0:
    s = img[i:i+220].split(b"\0")[0]
    print("banner:", s.decode("utf-8", "replace"))

for needle in [b"KernelSU", b"kernelsu", b"ksu_", b"/data/adb/ksud",
               b"CONFIG_KSU", b"ksud", b"KSU"]:
    c = img.count(needle)
    print(f"{needle!r}: {c} occurrence(s)")

m = re.search(rb"KernelSU[ -~]{0,60}", img)
if m:
    print("KernelSU string sample:", m.group(0)[:80])
