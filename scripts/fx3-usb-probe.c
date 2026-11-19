// fx3-usb-probe: Sony's PC Remote protocol (PTP + SDIO 0x92xx) over a USB-C cable with libusb, no Apple framework.
// The FX3 in MENU → Setup → USB → USB Connection Mode → Remote Shooting, plugged into a Mac:
//   L=$(brew --prefix libusb)   # brew install libusb
//   cc -O2 -o fx3-usb-probe scripts/fx3-usb-probe.c -I$L/include/libusb-1.0 -L$L/lib -lusb-1.0
//   ./fx3-usb-probe
// Runs the SDIO handshake, reads every property three times (full, then changed-only), streams live view for 5 s
// (fps, frame size; the first frame goes to /tmp/fx3-usb-lv.jpg), then closes the session.
// FX3 on USB (macOS): every op OK, 368 properties in 12 ms, live view 23 fps at 1024×576 (High).
#include <libusb.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

static libusb_device_handle *h; static uint8_t ep_out, ep_in; static uint32_t tid = 1;
static uint8_t buf[4 * 1024 * 1024], rx[4 * 1024 * 1024];
static uint16_t le16(const uint8_t *p) { return p[0] | p[1] << 8; }
static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

// Sends one command; reads an optional data phase into buf; returns the response code (data length in *dlen).
static int ptp(uint16_t code, int np, const uint32_t *p, int *dlen, uint32_t *rparam) {
    uint8_t c[32]; int len = 12 + 4 * np, n;
    c[0] = len; c[1] = len >> 8; c[2] = c[3] = 0; c[4] = 1; c[5] = 0; c[6] = code; c[7] = code >> 8;
    memcpy(c + 8, &tid, 4);
    for (int i = 0; i < np; i++) memcpy(c + 12 + 4 * i, &p[i], 4);
    tid++;
    if (libusb_bulk_transfer(h, ep_out, c, len, &n, 3000)) return -1;
    *dlen = 0;
    for (;;) {
        int got = 0, r = libusb_bulk_transfer(h, ep_in, rx, sizeof rx, &got, 10000);
        if (r || got < 12) return -2;
        uint32_t total = le32(rx); uint16_t type = le16(rx + 4);
        while ((uint32_t)got < total) {   // a container longer than one read
            int more = 0; if (libusb_bulk_transfer(h, ep_in, rx + got, sizeof rx - got, &more, 10000)) return -3;
            got += more;
        }
        if (type == 2) { *dlen = total - 12; memcpy(buf, rx + 12, *dlen); continue; }
        if (type == 3) { if (rparam) *rparam = total >= 16 ? le32(rx + 12) : 0; return le16(rx + 6); }
        return -4;
    }
}

int main(void) {
    if (libusb_init(NULL)) return 1;
    h = libusb_open_device_with_vid_pid(NULL, 0x054c, 0x0da3);
    if (!h) { puts("FX3 (054c:0da3) not found or can't be opened"); return 1; }
    struct libusb_config_descriptor *cfg; libusb_get_active_config_descriptor(libusb_get_device(h), &cfg);
    const struct libusb_interface_descriptor *ifd = &cfg->interface[0].altsetting[0];
    for (int i = 0; i < ifd->bNumEndpoints; i++) {
        const struct libusb_endpoint_descriptor *e = &ifd->endpoint[i];
        if ((e->bmAttributes & 3) == LIBUSB_TRANSFER_TYPE_BULK) { if (e->bEndpointAddress & 0x80) ep_in = e->bEndpointAddress; else ep_out = e->bEndpointAddress; }
    }
    printf("interface %d class %d/%d/%d, bulk out 0x%02x in 0x%02x\n", ifd->bInterfaceNumber, ifd->bInterfaceClass, ifd->bInterfaceSubClass, ifd->bInterfaceProtocol, ep_out, ep_in);
    int r = libusb_claim_interface(h, 0);
    if (r) { printf("claim interface: %s\n", libusb_error_name(r)); return 1; }
    int d; uint32_t rp = 0; double t;
    uint32_t one = 1; r = ptp(0x1002, 1, &one, &d, NULL); printf("OpenSession: 0x%04x\n", r);
    t = now_ms(); r = ptp(0x1001, 0, NULL, &d, NULL);
    printf("GetDeviceInfo: 0x%04x, %d B, %.0f ms\n", r, d, now_ms() - t);
    if (r == 0x2001 && d > 8) {
        const uint8_t *q = buf; printf("  PTP %u, vendor ext id 0x%08x v%u", le16(q), le32(q + 2), le16(q + 6)); q += 8;
        int sl = *q++; printf(", desc \""); for (int i = 0; i < sl - 1; i++) putchar(q[2 * i]); printf("\""); q += 2 * sl;
        printf(", functional mode %u\n", le16(q)); q += 2;
        uint32_t nops = le32(q); q += 4; int sony = 0; printf("  %u operations; Sony SDIO:", nops);
        for (uint32_t i = 0; i < nops; i++) { uint16_t op = le16(q + 2 * i); if (op >= 0x9200 && op < 0x9300) { printf(" 0x%04x", op); sony++; } }
        printf("%s\n", sony ? "" : " none");
        for (int i = 0; i + 8 < d; i += 2) if (buf[i] == 'I' && buf[i + 2] == 'L' && buf[i + 4] == 'M' && buf[i + 6] == 'E') { printf("  model: "); for (int j = i; j < d && buf[j]; j += 2) putchar(buf[j]); printf("\n"); break; }
    }
    uint32_t c1[] = {1, 0, 0}, c2[] = {2, 0, 0}, c3[] = {3, 0, 0}, ext[] = {0x012C, 1};
    t = now_ms(); r = ptp(0x9201, 3, c1, &d, NULL); printf("SDIO_Connect 1: 0x%04x %d B %.0f ms\n", r, d, now_ms() - t);
    t = now_ms(); r = ptp(0x9201, 3, c2, &d, NULL); printf("SDIO_Connect 2: 0x%04x %d B %.0f ms\n", r, d, now_ms() - t);
    for (int a = 0; a < 20; a++) {
        t = now_ms(); r = ptp(0x9202, 2, ext, &d, &rp);
        if (r != 0x2001 || d > 0) break;
        struct timespec s = {0, 100000000}; nanosleep(&s, NULL);
    }
    printf("SDIO_GetExtDeviceInfo: 0x%04x %d B, ext version %u, vendor code version 0x%x\n", r, d, d >= 2 ? le16(buf) : 0, rp);
    t = now_ms(); r = ptp(0x9201, 3, c3, &d, NULL); printf("SDIO_Connect 3: 0x%04x %d B %.0f ms\n", r, d, now_ms() - t);
    for (int k = 0; k < 3; k++) {
        t = now_ms(); r = ptp(0x9209, 1, &one, &d, NULL);
        printf("SDIO_GetAllExtDevicePropInfo #%d: 0x%04x %d B in %.0f ms\n", k + 1, r, d, now_ms() - t);
        if (r == 0x2001 && d >= 8) {   // count (UINT64), then the DevicePropInfo datasets
            uint64_t count = le32(buf) | (uint64_t)le32(buf + 4) << 32; printf("  %llu properties\n", (unsigned long long)count);
            for (int i = 8; k == 0 && i + 8 < d; i++) if (buf[i] == 0x6a && buf[i + 1] == 0xd2 && buf[i + 2] == 0x02 && buf[i + 3] == 0x00) { printf("  0xD26A live view quality: getset %u enabled %u default %u current %u (1 low, 2 high)\n", buf[i + 4], buf[i + 5], buf[i + 6], buf[i + 7]); break; }
        }
        struct timespec s = {0, 300000000}; nanosleep(&s, NULL);
    }
    uint32_t lv = 0xFFFFC002; r = ptp(0x1008, 1, &lv, &d, NULL); printf("GetObjectInfo(live view): 0x%04x %d B\n", r, d);
    int frames = 0, fails = 0; long bytes = 0; double t0 = now_ms(), slowest = 0;
    while (now_ms() - t0 < 5000) {
        double f = now_ms(); r = ptp(0x1009, 1, &lv, &d, NULL); double ms = now_ms() - f;
        if (r != 0x2001 || d < 16) { fails++; struct timespec s = {0, 30000000}; nanosleep(&s, NULL); continue; }
        uint32_t off = le32(buf), size = le32(buf + 4);
        if (!size || off + size > (uint32_t)d || buf[off] != 0xFF || buf[off + 1] != 0xD8) { fails++; struct timespec s = {0, 30000000}; nanosleep(&s, NULL); continue; }
        frames++; bytes += size; if (ms > slowest) slowest = ms;
        if (frames == 1) { FILE *o = fopen("/tmp/fx3-usb-lv.jpg", "wb"); fwrite(buf + off, 1, size, o); fclose(o); }
    }
    double secs = (now_ms() - t0) / 1000;
    printf("live view: %d frames in %.1f s = %.1f fps, avg %ld B/frame, slowest %.0f ms, %d not ready (0x200F)\n", frames, secs, frames / secs, frames ? bytes / frames : 0, slowest, fails);
    r = ptp(0x1003, 0, NULL, &d, NULL); printf("CloseSession: 0x%04x\n", r);
    libusb_release_interface(h, 0); libusb_close(h); libusb_exit(NULL);
    return 0;
}
