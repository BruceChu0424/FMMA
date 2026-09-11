#include "fmma_socfpga.h"
#include "fmma_log.h"

#include <stdio.h>
#include <string.h>

#define TAG "fabric"

/* The 3.13 Altera kernel exposes /sys/class/fpga/fpga0/status; mainline
 * later moved it to /sys/class/fpga_manager/fpga0/state.  Try both. */
static const char *k_status_paths[] = {
    "/sys/class/fpga/fpga0/status",
    "/sys/class/fpga_manager/fpga0/state",
    NULL
};

static char s_text[64] = "unknown";

enum fmma_fabric_state fmma_fabric_state(void)
{
    for (int i = 0; k_status_paths[i]; i++) {
        FILE *f = fopen(k_status_paths[i], "r");
        if (f == NULL) continue;
        char buf[64] = {0};
        char *got = fgets(buf, sizeof(buf), f);
        fclose(f);
        if (got == NULL) continue;

        buf[strcspn(buf, "\r\n")] = '\0';
        snprintf(s_text, sizeof(s_text), "%s", buf);

        /* "user mode" on the Altera driver, "operating" on mainline. */
        if (strstr(buf, "user mode") || strstr(buf, "operating"))
            return FMMA_FABRIC_USER_MODE;
        return FMMA_FABRIC_UNCONFIGURED;
    }
    snprintf(s_text, sizeof(s_text), "no FPGA manager");
    return FMMA_FABRIC_UNKNOWN;
}

const char *fmma_fabric_state_text(void)
{
    return s_text;
}

int fmma_fabric_check(int force)
{
    enum fmma_fabric_state st = fmma_fabric_state();

    switch (st) {
    case FMMA_FABRIC_USER_MODE:
        FMMA_DEBUG(TAG, "FPGA is configured (%s)", s_text);
        return 0;

    case FMMA_FABRIC_UNCONFIGURED:
        FMMA_ERROR(TAG, "the FPGA is NOT configured (status: %s)", s_text);
        FMMA_ERROR(TAG, "refusing to touch the bridge: an access with no");
        FMMA_ERROR(TAG, "slave behind it never completes and hangs the board");
        FMMA_ERROR(TAG, "program the fabric first - see docs/11 section 11.4");
        return force ? 0 : -1;

    default:
        if (force) {
            FMMA_WARN(TAG, "cannot determine the FPGA state (%s); "
                           "continuing because --force was given", s_text);
            return 0;
        }
        FMMA_ERROR(TAG, "cannot determine whether the FPGA is configured "
                        "(%s)", s_text);
        FMMA_ERROR(TAG, "pass --force to map the bridge anyway, but be sure: "
                        "an access to an unconfigured fabric hangs the board");
        return -1;
    }
}
