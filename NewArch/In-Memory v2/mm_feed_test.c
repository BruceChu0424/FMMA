#define _DEFAULT_SOURCE

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

// FPGA physical address
#define FPGA_BASE  0xC0040000
#define MAP_SIZE   0x24000

// Global registers
#define REG_ID           0x00000
#define REG_CTRL         0x00004
#define REG_STATUS       0x00008
#define REG_FEED_SYMBOL  0x0000C
#define REG_FEED_LEVEL   0x00010
#define REG_FEED_DELTA   0x00014
#define REG_FEED_SUBMIT  0x00018

// Symbol 0, bid quantity level 0
#define REG_BID_QTY0     0x22000

#define TEST_DELTA       1000

int main(void)
{
    int fd;
    volatile uint32_t *regs;
    uint32_t after = 0;
    int success = 0;

    printf("=== FPGA Feed Communication Test ===\n");

    // Open physical memory
    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    // Map FPGA register space
    regs = (volatile uint32_t *)mmap(
        NULL,
        MAP_SIZE,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        fd,
        FPGA_BASE
    );

    if (regs == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    // Verify FPGA
    uint32_t id = regs[REG_ID / 4];
    uint32_t status = regs[REG_STATUS / 4];

    printf("FPGA ID: 0x%08X\n", id);
    printf("STATUS:  0x%08X\n", status);

    if (id != 0x4D4D0100) {
        printf("ERROR: Unexpected FPGA ID.\n");
        goto cleanup;
    }

    if ((status & 1) == 0) {
        printf("ERROR: FPGA core is not ready.\n");
        goto cleanup;
    }

    // Read current BTC bid quantity at level 0
    uint32_t before = regs[REG_BID_QTY0 / 4];

    printf("\nInitial BTC bid quantity: %u\n", before);

    // Configure feed update:
    // Symbol 0 = BTC
    // Side 0   = Bid
    // Level 0
    // Delta    = +1000

    regs[REG_FEED_SYMBOL / 4] = 0;
    regs[REG_FEED_LEVEL / 4]  = 0;
    regs[REG_FEED_DELTA / 4]  = TEST_DELTA;

    // Submit update
    regs[REG_FEED_SUBMIT / 4] = 1;

    // Ensure writes are issued before reading back
    __sync_synchronize();

    printf("Sent FPGA feed update: +%d\n", TEST_DELTA);

    // Allow the book RAM update pipeline to finish
    usleep(1000);

    // Read updated quantity
    after = regs[REG_BID_QTY0 / 4];
    uint32_t expected = before + TEST_DELTA;

    printf("\nUpdated BTC bid quantity: %u\n", after);
    printf("Expected quantity:        %u\n", expected);

    if (after == expected) {
	success = 1;
        printf("\nSUCCESS: HPS -> FPGA -> HPS communication verified!\n");
    } else {
        printf("\nFAILURE: Readback does not match expected quantity.\n");
        printf("Check the AXI feed path and book RAM update logic.\n");
    }

cleanup:
    munmap((void *)regs, MAP_SIZE);
    close(fd);

    return success ? 0 : 1;
}
