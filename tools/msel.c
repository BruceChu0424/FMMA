/*
 * Read the Cyclone V FPGA manager's MSEL strap.
 *
 * MSEL[4:0] is set by DIP switches on the board and decides how the
 * FPGA is configured.  It matters here because the HPS can only
 * configure the fabric in one of the Fast Passive Parallel modes; in
 * Active Serial mode the FPGA loads itself from the on-board flash and
 * the Linux driver refuses with nothing more helpful than
 * "Invalid MSEL setting" followed by a timeout.
 *
 * fpgamgrregs.stat lives at 0xFF706000: bits [2:0] are the current mode
 * and bits [7:3] are the MSEL strap.  That is an HPS peripheral
 * register, not the FPGA bridge, so reading it is always safe - unlike
 * the bridge, which hangs the board if the fabric is unconfigured.
 *
 * Prints the raw MSEL value on stdout so a script can parse it, and a
 * human-readable summary on stderr.
 *
 *     gcc -O2 -o msel msel.c && ./msel
 */

#include <stdint.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define FPGAMGR_BASE 0xFF706000UL

int main(void)
{
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "open /dev/mem failed (run as root)\n");
        return 1;
    }

    void *m = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, FPGAMGR_BASE);
    if (m == MAP_FAILED) {
        fprintf(stderr, "mmap of the FPGA manager failed\n");
        close(fd);
        return 1;
    }

    uint32_t stat = *(volatile uint32_t *)m;
    unsigned mode = stat & 0x7;
    unsigned msel = (stat >> 3) & 0x1F;

    static const char *modes[8] = {
        "power off", "reset phase", "configuration phase",
        "initialisation phase", "user mode", "?", "?", "?"
    };

    /* stdout: just the number, for scripts. */
    printf("%u\n", msel);

    fprintf(stderr, "fpgamgr stat 0x%08x  mode %u (%s)  MSEL %u%u%u%u%u\n",
            stat, mode, modes[mode],
            (msel >> 4) & 1, (msel >> 3) & 1, (msel >> 2) & 1,
            (msel >> 1) & 1, msel & 1);

    munmap(m, 4096);
    close(fd);
    return 0;
}
