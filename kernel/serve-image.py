#!/usr/bin/env python3
"""Serve a NixOS image to the DS410j flasher over HTTP, and print the U-Boot
commands that consume it.

The flasher (kernel/flasher.nix + kernel/flash-init.sh) streams its payload over
plain HTTP because the image is ~700 MB against 118 MB of RAM. OPERATIONS.md
used to record that an HTTP server "was refused by the sandbox"; that is not
true - a bind on 192.168.50.1:8080 succeeds. What IS true is that
`python3 -m http.server` silently ignores Range requests, which looks exactly
like a hang when you probe it with `curl -r`. Hence this file: threaded, real
Range support, and progress logging so a stalled flash is visible from here.

    /src/kernel/serve-image.py                  # serve nixos/result-image
    /src/kernel/serve-image.py --image PATH
    /src/kernel/serve-image.py --no-hash        # skip the sha256 (it costs ~10 s)

Ctrl-C to stop. Nothing here writes to the device or to flash.
"""
import argparse, hashlib, os, socket, sys, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

DEFAULT_LINK = "/src/nixos/result-image"
BENCH_IP = "192.168.50.1"
BENCH_PORT = 8080
SERVED_AS = "ds410j-nixos.img"


try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass


def find_image(explicit):
    if explicit:
        return os.path.realpath(explicit)
    sd = os.path.join(os.path.realpath(DEFAULT_LINK), "sd-image")
    if not os.path.isdir(sd):
        sys.exit(f"no sd-image dir under {DEFAULT_LINK} - run: nix-build /src/nixos -A image -o {DEFAULT_LINK}")
    imgs = [f for f in os.listdir(sd) if f.endswith(".img")]
    if len(imgs) != 1:
        sys.exit(f"expected exactly one .img in {sd}, found {imgs}")
    return os.path.join(sd, imgs[0])


def sha256_of(path, size):
    h = hashlib.sha256()
    done = 0
    t0 = time.time()
    with open(path, "rb") as f:
        while chunk := f.read(4 << 20):
            h.update(chunk)
            done += len(chunk)
            if sys.stdout.isatty():
                pct = 100.0 * done / size
                print(f"\r  hashing {pct:5.1f}%", end="", flush=True)
    print(f"{chr(13) if sys.stdout.isatty() else ''}  hashed in {time.time() - t0:.1f} s      ")
    return h.hexdigest()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    image = None
    size = 0

    def log_message(self, fmt, *a):  # quieter default log
        pass

    def _range(self):
        """Parse a single byte range. Returns (start, end_inclusive) or None."""
        hdr = self.headers.get("Range")
        if not hdr or not hdr.startswith("bytes="):
            return None
        spec = hdr[len("bytes="):].split(",")[0].strip()
        first, _, last = spec.partition("-")
        if first == "":                      # suffix range: bytes=-N
            n = int(last)
            return max(0, self.size - n), self.size - 1
        start = int(first)
        end = int(last) if last else self.size - 1
        return start, min(end, self.size - 1)

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", str(self.size))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

    def do_GET(self):
        rng = self._range()
        if rng and rng[0] >= self.size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{self.size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if rng:
            start, end = rng
            length = end - start + 1
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{self.size}")
        else:
            start, length = 0, self.size
            self.send_response(200)
        self.send_header("Content-Length", str(length))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

        peer = self.client_address[0]
        print(f"[serve] {peer} GET {length} bytes from offset {start}")
        t0 = time.time()
        sent = 0
        last_report = 0.0
        try:
            with open(self.image, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(1 << 20, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    sent += len(chunk)
                    remaining -= len(chunk)
                    now = time.time()
                    if now - last_report >= 5.0:
                        rate = sent / (now - t0) / 1e6
                        pct = 100.0 * sent / length
                        print(f"[serve] {peer} {pct:5.1f}%  {sent/1e6:7.1f}/{length/1e6:.1f} MB  {rate:5.2f} MB/s")
                        last_report = now
        except (BrokenPipeError, ConnectionResetError):
            el = time.time() - t0
            print(f"[serve] {peer} DISCONNECTED after {sent/1e6:.1f} MB in {el:.1f} s "
                  f"({sent/el/1e6 if el else 0:.2f} MB/s) - the flash did NOT complete")
            return
        el = max(time.time() - t0, 1e-6)
        print(f"[serve] {peer} sent {sent/1e6:.1f} MB in {el:.1f} s ({sent/el/1e6:.2f} MB/s)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image")
    ap.add_argument("--ip", default=BENCH_IP)
    ap.add_argument("--port", type=int, default=BENCH_PORT)
    ap.add_argument("--no-hash", action="store_true")
    args = ap.parse_args()

    img = find_image(args.image)
    size = os.path.getsize(img)
    print(f"image  : {img}")
    print(f"size   : {size} bytes ({size/1e6:.1f} MB)")
    sha = "" if args.no_hash else sha256_of(img, size)
    if sha:
        print(f"sha256 : {sha}")

    Handler.image, Handler.size = img, size
    srv = ThreadingHTTPServer((args.ip, args.port), Handler)
    srv.daemon_threads = True
    url = f"http://{args.ip}:{args.port}/{SERVED_AS}"

    print()
    print("=" * 74)
    print(" Paste at the U-Boot prompt (our U-Boot 2026.07, separate DTB):")
    print("=" * 74)
    print(f"""
setenv serverip {args.ip}
setenv ipaddr 192.168.50.50
tftpboot 0x00800000 zImage-flasher
tftpboot 0x02000000 kirkwood-ds409-flasher.dtb
setenv bootargs 'console=ttyS0,115200n8 flash.url={url}{"" if not sha else " flash.sha256=" + sha} flash.size={size} flash.dev=auto flash.ip=192.168.50.60 flash.reboot=1'
bootz 0x00800000 - 0x02000000
""")
    print("=" * 74)
    print(" Or from the STOCK Marvell 1.1.4 prompt (appended DTB, no `fdt`):")
    print("=" * 74)
    print(f"""
setenv serverip {args.ip}
setenv ipaddr 192.168.50.50
setenv bootargs 'console=ttyS0,115200n8 flash.url={url}{"" if not sha else " flash.sha256=" + sha} flash.size={size} flash.dev=auto flash.ip=192.168.50.60 flash.reboot=1'
tftpboot 0x00800000 uImage-flasher
bootm 0x00800000
""")
    print("=" * 74)
    # 244 chars with a sha256 in it. Our U-Boot 2026.07 has CONFIG_SYS_CBSIZE=1024
    # so it is fine there, but the stock Marvell 1.1.4 is the path that matters
    # most (it is the one that works when mtd1 is broken) and 1.1.4-era boards
    # were often built with CBSIZE=256. That fits, barely, with no margin - so
    # here is the same thing in pieces, none over ~130 chars.
    one = f"console=ttyS0,115200n8 flash.dev=auto flash.ip=192.168.50.60 flash.reboot=1"
    print(" If the loader truncates that line (CBSIZE), build it up instead:")
    print("=" * 74)
    print(f"""
setenv bootargs '{one}'
setenv bootargs "$bootargs flash.url={url}"{"" if not sha else chr(10) + 'setenv bootargs "$bootargs flash.sha256=' + sha + '"'}
setenv bootargs "$bootargs flash.size={size}"
printenv bootargs
""")
    print("=" * 74)
    print(f"serving {SERVED_AS} on {url} - Ctrl-C to stop")
    print()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[serve] stopped")


if __name__ == "__main__":
    main()
