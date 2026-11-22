import struct, zlib, re

path = r"C:\Users\dcj\Desktop\new-boot.img"
data = open(path, "rb").read()
(kernel_size, *rest) = struct.unpack_from("<10I", data, 8)
page_size = rest[6]
kernel = data[page_size:page_size + kernel_size]
d = zlib.decompressobj(31)
img = d.decompress(kernel) + d.flush()

def strings(buf, minlen=6):
    out = []
    for m in re.finditer(rb"[ -~]{%d,}" % minlen, buf):
        out.append(m.group(0))
    return out

ss = strings(img, 6)
ksu = [s for s in ss if b"ksu" in s.lower() or b"KernelSU" in s]
print("total strings:", len(ss), "ksu-related:", len(ksu))
seen = set()
for s in ksu:
    t = s[:120]
    if t in seen:
        continue
    seen.add(t)

for t in list(seen)[:80]:
    print(t.decode("utf-8", "replace"))

print("\n--- markers ---")
for pat in [b"sucompat", b"execve_kp", b"faccessat su->sh!", b"newfstatat su->sh!",
            b"do_execveat_common su found", b"ksu_show_allow_list", b"KernelSU:",
            b"ksu_handle", b"kprobe", b"KSURC", b"ksud"]:
    print(f"{pat.decode():35s} {img.count(pat)}")
