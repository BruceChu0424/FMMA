
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define MM_PHYS_BASE 0xC0040000UL
#define MAP_SIZE     4096

int main(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    volatile uint32_t *regs = mmap(
        NULL, MAP_SIZE,
        PROT_READ | PROT_WRITE,
        MAP_SHARED, fd, MM_PHYS_BASE
    );

    if (regs == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    uint32_t id     = regs[0];  // offset 0x00
    uint32_t ctrl   = regs[1];  // offset 0x04
    uint32_t status = regs[2];  // offset 0x08

    printf("FPGA ID:     0x%08X\n", id);
    printf("CTRL:        0x%08X\n", ctrl);
    printf("STATUS:      0x%08X\n", status);

    munmap((void *) regs, MAP_SIZE);
    close(fd);

    return id == 0x4D4D0100 ? 0 : 2;
}
