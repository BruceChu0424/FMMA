/*
 * fmma-probe - a standalone diagnostic for the HPS-to-FPGA link.
 *
 * Deliberately depends on nothing but libc, so it builds in a second on
 * the board and works before the main application does.  It is the first
 * thing to run during bring-up and the first thing to reach for when
 * something is wrong: it answers "is the FPGA configured with our design,
 * and is the CPU running?" without involving TLS, the network or a broker.
 *
 *   fmma-probe                 summarise the protocol block
 *   fmma-probe watch           follow the heartbeat and signals
 *   fmma-probe ramtest         prove the window really is our shared RAM
 *   fmma-probe dump [n]        hex dump the first n words
 *   fmma-probe read  <word>
 *   fmma-probe write <word> <value>
 *
 * Word indices are the ones in docs/07-shared-memory-protocol.md.
 */

#include "../fmma_protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#define LW_H2F_BASE 0xFF200000UL
#define MAP_BYTES   (FMMA_MEM_WORDS * 4u)

static volatile uint32_t *g_regs;
static void *g_map = MAP_FAILED;
static int g_fd = -1;
static volatile sig_atomic_t g_stop;

static void on_sigint(int s) { (void)s; g_stop = 1; }

static int map_bridge(void)
{
    g_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_fd == -1) {
        fprintf(stderr, "open /dev/mem: %s (run as root)\n", strerror(errno));
        return -1;
    }
    g_map = mmap(NULL, MAP_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED,
                 g_fd, LW_H2F_BASE);
    if (g_map == MAP_FAILED) {
        fprintf(stderr, "mmap 0x%lX: %s\n", LW_H2F_BASE, strerror(errno));
        close(g_fd);
        return -1;
    }
    g_regs = (volatile uint32_t *)g_map;
    return 0;
}

static void unmap_bridge(void)
{
    if (g_map != MAP_FAILED) munmap(g_map, MAP_BYTES);
    if (g_fd != -1) close(g_fd);
}

static const char *status_text(uint32_t s, char *buf, size_t n)
{
    snprintf(buf, n, "0x%X%s%s%s", s,
             (s & FMMA_STATUS_RUNNING)      ? " running"      : "",
             (s & FMMA_STATUS_RISK_BLOCKED) ? " risk-blocked" : "",
             (s & FMMA_STATUS_DISABLED)     ? " disabled"     : "");
    return buf;
}

/* ------------------------------------------------------------------ */

static int cmd_summary(void)
{
    char sbuf[64];
    uint32_t version = g_regs[FMMA_FW_VERSION];

    printf("shared RAM at 0x%lX, %u words\n\n", LW_H2F_BASE, FMMA_MEM_WORDS);

    printf("  FW_VERSION   %10u   %s\n", version,
           version == FMMA_PROTOCOL_VERSION ? "(matches this build)" :
           version == 0 ? "(CPU has not started, or its datapath probe failed)"
                        : "(MISMATCH - rebuild the bitstream and the program)");
    printf("  HEARTBEAT    %10u\n", g_regs[FMMA_HEARTBEAT]);
    printf("  STATUS       %10s\n", status_text(g_regs[FMMA_STATUS],
                                                sbuf, sizeof(sbuf)));
    printf("  POSITION     %10d lots\n", (int32_t)g_regs[FMMA_POSITION]);
    printf("  REJECTS      %10u\n", g_regs[FMMA_REJECTS]);
    printf("  SIGNAL       %10u   SIGNAL_SEQ %u, from tick %u\n",
           g_regs[FMMA_SIGNAL], g_regs[FMMA_SIGNAL_SEQ],
           g_regs[FMMA_SIGNAL_TICK]);
    printf("  QUOTE_BID    %10u   QUOTE_ASK %u\n",
           g_regs[FMMA_QUOTE_BID], g_regs[FMMA_QUOTE_ASK]);
    printf("\n");
    printf("  TICK_SEQ     %10u   %s\n", g_regs[FMMA_TICK_SEQ],
           (g_regs[FMMA_TICK_SEQ] & 1u) ? "(odd: a write is in progress)"
                                        : "(even: stable)");
    printf("  BID          %10u   ASK %u\n",
           g_regs[FMMA_BID], g_regs[FMMA_ASK]);
    printf("  CFG_THRESH   %10u   CFG_MAX_POS %u   CFG_ENABLE %u\n",
           g_regs[FMMA_CFG_THRESH], g_regs[FMMA_CFG_MAX_POS],
           g_regs[FMMA_CFG_ENABLE]);
    return 0;
}

static int cmd_watch(void)
{
    uint32_t beat = g_regs[FMMA_HEARTBEAT];
    uint32_t sig  = g_regs[FMMA_SIGNAL_SEQ];
    char sbuf[64];

    signal(SIGINT, on_sigint);
    printf("watching (Ctrl-C to stop)\n");
    printf("%12s %12s %10s %8s  %s\n",
           "heartbeat", "loops/s", "position", "rejects", "status");

    while (!g_stop) {
        sleep(1);
        uint32_t b = g_regs[FMMA_HEARTBEAT];
        uint32_t delta = b - beat;
        beat = b;

        printf("%12u %12u %10d %8u  %s\n", b, delta,
               (int32_t)g_regs[FMMA_POSITION], g_regs[FMMA_REJECTS],
               status_text(g_regs[FMMA_STATUS], sbuf, sizeof(sbuf)));

        uint32_t s = g_regs[FMMA_SIGNAL_SEQ];
        if (s != sig) {
            printf("   >>> SIGNAL %s (seq %u, from tick %u)\n",
                   g_regs[FMMA_SIGNAL] == FMMA_SIGNAL_BUY  ? "BUY"  :
                   g_regs[FMMA_SIGNAL] == FMMA_SIGNAL_SELL ? "SELL" : "?",
                   s, g_regs[FMMA_SIGNAL_TICK]);
            sig = s;
        }
    }
    printf("\n");
    return 0;
}

/*
 * Prove the mapped window is really our dual-port RAM and not some other
 * peripheral that happens to live at this address.  A PIO register block
 * - which is what the stock DE1-SoC reference design puts here - fails
 * this immediately: the reads do not return what was written, and the
 * addresses alias.
 *
 * Only the free region above the protocol block is touched, so this is
 * safe to run against a CPU that is executing.
 */
static int cmd_ramtest(void)
{
    const unsigned base = 512;                 /* well inside the free area */
    const unsigned count = 256;
    unsigned errors = 0;

    printf("RAM test on words %u..%u (the free region)\n",
           base, base + count - 1);

    uint32_t saved[256];
    for (unsigned i = 0; i < count; i++) saved[i] = g_regs[base + i];

    /* 1. unique value per word - catches address aliasing */
    for (unsigned i = 0; i < count; i++) g_regs[base + i] = 0xA5A50000u + i;
    for (unsigned i = 0; i < count; i++) {
        uint32_t got = g_regs[base + i];
        if (got != 0xA5A50000u + i) {
            if (errors < 8)
                printf("  word %u: wrote 0x%08X read 0x%08X\n",
                       base + i, 0xA5A50000u + i, got);
            errors++;
        }
    }

    /* 2. walking ones - catches stuck data bits */
    for (unsigned bit = 0; bit < 32; bit++) {
        uint32_t pattern = 1u << bit;
        g_regs[base] = pattern;
        uint32_t got = g_regs[base];
        if (got != pattern) {
            printf("  data bit %u stuck: wrote 0x%08X read 0x%08X\n",
                   bit, pattern, got);
            errors++;
        }
    }

    for (unsigned i = 0; i < count; i++) g_regs[base + i] = saved[i];

    if (errors == 0) {
        printf("  PASS - %u words, 32 data bits, no errors\n", count);
        printf("  the window behaves as read/write RAM, so the FPGA is\n");
        printf("  configured with a design that puts the shared memory here\n");
        return 0;
    }
    printf("  FAIL - %u errors\n", errors);
    printf("  the FPGA is probably not configured, or is configured with a\n");
    printf("  different design (the stock reference design puts PIO\n");
    printf("  registers at this address, which fail exactly like this)\n");
    return 1;
}

static int cmd_dump(int argc, char **argv)
{
    unsigned n = (argc > 2) ? (unsigned)strtoul(argv[2], NULL, 0) : 32;
    if (n > FMMA_MEM_WORDS) n = FMMA_MEM_WORDS;
    for (unsigned i = 0; i < n; i += 4) {
        printf("  %4u:", i);
        for (unsigned j = 0; j < 4 && i + j < n; j++)
            printf("  %08X", g_regs[i + j]);
        printf("\n");
    }
    return 0;
}

static int cmd_read(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "read <word>\n"); return 2; }
    unsigned w = (unsigned)strtoul(argv[2], NULL, 0);
    if (w >= FMMA_MEM_WORDS) { fprintf(stderr, "word out of range\n"); return 2; }
    printf("%u\n", g_regs[w]);
    return 0;
}

static int cmd_write(int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "write <word> <value>\n"); return 2; }
    unsigned w = (unsigned)strtoul(argv[2], NULL, 0);
    uint32_t v = (uint32_t)strtoul(argv[3], NULL, 0);
    if (w >= FMMA_MEM_WORDS) { fprintf(stderr, "word out of range\n"); return 2; }
    if (w >= FMMA_OUTPUT_BASE && w < FMMA_OUTPUT_BASE + 64)
        fprintf(stderr, "warning: word %u belongs to the FPGA; the protocol "
                        "says the host never writes here\n", w);
    g_regs[w] = v;
    return 0;
}

static void usage(void)
{
    printf("fmma-probe - HPS/FPGA link diagnostic (protocol v%u)\n\n"
           "  fmma-probe                 summarise the protocol block\n"
           "  fmma-probe watch           follow the heartbeat and signals\n"
           "  fmma-probe ramtest         prove the window is our shared RAM\n"
           "  fmma-probe dump [n]        hex dump the first n words\n"
           "  fmma-probe read  <word>\n"
           "  fmma-probe write <word> <value>\n",
           FMMA_PROTOCOL_VERSION);
}

int main(int argc, char **argv)
{
    if (argc > 1 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
        usage();
        return 0;
    }
    if (map_bridge() != 0) return 1;

    int rc;
    if (argc < 2)                        rc = cmd_summary();
    else if (!strcmp(argv[1], "watch"))  rc = cmd_watch();
    else if (!strcmp(argv[1], "ramtest"))rc = cmd_ramtest();
    else if (!strcmp(argv[1], "dump"))   rc = cmd_dump(argc, argv);
    else if (!strcmp(argv[1], "read"))   rc = cmd_read(argc, argv);
    else if (!strcmp(argv[1], "write"))  rc = cmd_write(argc, argv);
    else { usage(); rc = 2; }

    unmap_bridge();
    return rc;
}
