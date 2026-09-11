/*
 * FMMA - FPGA Market Maker Accelerator
 * HPS-side application: market data -> FPGA -> order execution
 *
 * Data flow:
 *   Coinbase WebSocket (BTC-USD matches)
 *     -> parsed here, written into the shared on-chip RAM over the
 *        lightweight HPS-to-FPGA bridge (mmap of 0xFF200000)
 *     -> the custom CPU in the FPGA fabric runs trading.asm and
 *        writes a SIGNAL word + a HEARTBEAT counter
 *     -> this program polls the signal and sends paper orders to
 *        the Alpaca trading API
 *
 * Shared RAM layout (word indices, see Documents/PROTOCOL.md):
 *   FPGA_PROGRAM_BASE .. +44 : trading program (written once at start)
 *   64 BUY_PRICE   65 SELL_PRICE   68 BUY_SIZE   69 SELL_SIZE  (HPS -> FPGA)
 *   66 SIGNAL (1=buy, 2=sell)       67 HEARTBEAT               (FPGA -> HPS)
 *
 * Alpaca paper-trading credentials are read from the environment:
 *   export APCA_API_KEY_ID=...      export APCA_API_SECRET_KEY=...
 * Never commit real keys to the repository.
 *
 * Build (on the board, or cross-compile): see Software/Makefile.
 */

#include "mongoose.h"
#include "fpga_program.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

/* ------------------------------------------------------------------ */
/* Configuration                                                       */
/* ------------------------------------------------------------------ */

/* Coinbase market data (input) */
static const char *s_coinbase_url = "wss://ws-feed.exchange.coinbase.com";
static const char *s_sub_msg =
    "{\"type\":\"subscribe\",\"product_ids\":[\"BTC-USD\"],\"channels\":[\"matches\"]}";

/* Alpaca paper trading (output) - credentials from the environment */
static const char *s_alpaca_url    = "https://paper-api.alpaca.markets/v2/orders";
static const char *s_alpaca_host   = "paper-api.alpaca.markets";
static const char *s_alpaca_key    = NULL;   /* APCA_API_KEY_ID     */
static const char *s_alpaca_secret = NULL;   /* APCA_API_SECRET_KEY */
static const char *s_order_symbol  = "BTCUSD";
static const char *s_order_qty     = "0.001";

/* FPGA memory map - lightweight HPS-to-FPGA bridge (see Documents/PROTOCOL.md) */
#define LW_H2F_BASE     0xFF200000UL
#define MAP_SIZE        4096

/* Word indices inside the 4 KB shared on-chip RAM */
#define WORD_BUY_PRICE   64   /* 0x100: last buy-side trade price  x10000 */
#define WORD_SELL_PRICE  65   /* 0x104: last sell-side trade price x10000 */
#define WORD_SIGNAL      66   /* 0x108: 1 = buy, 2 = sell (FPGA -> HPS)   */
#define WORD_HEARTBEAT   67   /* 0x10C: CPU loop counter (FPGA -> HPS)    */
#define WORD_BUY_SIZE    68   /* 0x110: last buy-side trade size          */
#define WORD_SELL_SIZE   69   /* 0x114: last sell-side trade size         */

/* Rate limiting (TRADE_COOLDOWN_MS < 500 gets the Alpaca account banned) */
#define THROTTLE_MS        200
#define TRADE_COOLDOWN_MS 1000

/* ------------------------------------------------------------------ */
/* Globals                                                             */
/* ------------------------------------------------------------------ */

static volatile unsigned int *fpga_regs = NULL;  /* window onto the shared RAM */
static int mem_fd = -1;
static unsigned long last_process_time = 0;
static unsigned long last_trade_time   = 0;
static unsigned int  last_heartbeat    = 0;
static struct mg_mgr mgr;

static unsigned long get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long)(ts.tv_sec * 1000) + (unsigned long)(ts.tv_nsec / 1000000);
}

/* ------------------------------------------------------------------ */
/* FPGA loader: write the trading program, wait for the CPU to run     */
/* ------------------------------------------------------------------ */

static int load_fpga_program(void) {
    if (!fpga_regs) return -1;

    /* The RAM powers up zeroed; a zero word parks the CPU in a wait
     * state (FSMTrial 'hlt'), so it is safe to write the program while
     * the CPU is already watching. */
    printf("[LOADER] Writing %u program words at word %u...\n",
           FPGA_PROGRAM_LEN, FPGA_PROGRAM_BASE);
    for (unsigned int i = 0; i < FPGA_PROGRAM_LEN; i++)
        fpga_regs[FPGA_PROGRAM_BASE + i] = fpga_program[i];

    /* Verify the readback (catches a wrong bridge base address) */
    for (unsigned int i = 0; i < FPGA_PROGRAM_LEN; i++) {
        if (fpga_regs[FPGA_PROGRAM_BASE + i] != fpga_program[i]) {
            printf("[LOADER] ERROR: readback mismatch at word %u (bridge base 0x%X)\n",
                   FPGA_PROGRAM_BASE + i, (unsigned) LW_H2F_BASE);
            return -1;
        }
    }
    printf("[LOADER] Program verified.\n");

    /* Clear the data/signal area before the CPU starts trading */
    fpga_regs[WORD_BUY_PRICE]  = 0;
    fpga_regs[WORD_SELL_PRICE] = 0;
    fpga_regs[WORD_SIGNAL]     = 0;
    fpga_regs[WORD_HEARTBEAT]  = 0;
    fpga_regs[WORD_BUY_SIZE]   = 0;
    fpga_regs[WORD_SELL_SIZE]  = 0;
    return 0;
}

static void wait_for_cpu(void) {
    if (!fpga_regs) return;
    printf("[LOADER] Waiting for the CPU heartbeat (word %d)...\n", WORD_HEARTBEAT);
    for (int i = 0; i < 50; i++) {           /* up to ~5 s */
        if (fpga_regs[WORD_HEARTBEAT] != 0) {
            printf("[LOADER] CPU is running (heartbeat = %u).\n",
                   fpga_regs[WORD_HEARTBEAT]);
            return;
        }
        usleep(100000);
    }
    printf("[LOADER] WARNING: no heartbeat - check the FPGA bitstream/memory map.\n");
}

/* ------------------------------------------------------------------ */
/* Alpaca execution                                                    */
/* ------------------------------------------------------------------ */

static void alpaca_cb(struct mg_connection *c, int ev, void *ev_data) {
    if (ev == MG_EV_CONNECT) {
        struct mg_tls_opts opts = {
            .ca   = mg_str(""),
            .name = mg_str(s_alpaca_host)   /* SNI is required by Alpaca */
        };
        mg_tls_init(c, &opts);
    } else if (ev == MG_EV_HTTP_MSG) {
        struct mg_http_message *hm = (struct mg_http_message *) ev_data;
        printf("[ALPACA] Response: %.*s\n", (int) hm->message.len, hm->message.buf);
        c->is_draining = 1;
    }
    (void) ev_data;
}

static void send_order_to_alpaca(const char *side) {
    unsigned long now = get_time_ms();
    if (now - last_trade_time < TRADE_COOLDOWN_MS) {
        printf("[EXECUTION] Cooldown active, ignoring %s signal.\n", side);
        return;
    }
    if (!s_alpaca_key || !s_alpaca_secret) {
        printf("[EXECUTION] Alpaca keys not set (APCA_API_KEY_ID/SECRET), skipping %s.\n", side);
        return;
    }

    printf("*** [EXECUTION] Sending %s order to Alpaca ***\n", side);

    struct mg_connection *c = mg_http_connect(&mgr, s_alpaca_url, alpaca_cb, NULL);
    if (!c) {
        printf("[EXECUTION] Failed to create connection.\n");
        return;
    }

    char body[256];
    snprintf(body, sizeof(body),
             "{\"symbol\":\"%s\",\"qty\":\"%s\",\"side\":\"%s\",\"type\":\"market\",\"time_in_force\":\"gtc\"}",
             s_order_symbol, s_order_qty, side);

    mg_printf(c,
        "POST /v2/orders HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "APCA-API-KEY-ID: %s\r\n"
        "APCA-API-SECRET-KEY: %s\r\n"
        "\r\n"
        "%s",
        s_alpaca_host, (int) strlen(body), s_alpaca_key, s_alpaca_secret, body);

    last_trade_time = now;
}

/* ------------------------------------------------------------------ */
/* FPGA communication                                                  */
/* ------------------------------------------------------------------ */

static void update_fpga_input(unsigned int price, unsigned int size, const char *side) {
    if (!fpga_regs || !side) return;

    char c = side[0];   /* 'b' or 's' */
    if (c == 'b' || c == 'B') {
        fpga_regs[WORD_BUY_PRICE] = price;
        fpga_regs[WORD_BUY_SIZE]  = size;
    } else if (c == 's' || c == 'S') {
        fpga_regs[WORD_SELL_PRICE] = price;
        fpga_regs[WORD_SELL_SIZE]  = size;
    } else {
        printf("[FPGA] Unknown side '%c' - ignoring\n", c);
    }
}

static void check_fpga_decision(void) {
    if (!fpga_regs) return;

    unsigned int heartbeat = fpga_regs[WORD_HEARTBEAT];
    if (heartbeat != last_heartbeat) {
        /* Visible proof that the CPU in the fabric is alive */
        printf("[FPGA] heartbeat = %u\n", heartbeat);
        last_heartbeat = heartbeat;
    }

    unsigned int signal = fpga_regs[WORD_SIGNAL];
    if (signal == 1) {
        printf(">>> [FPGA] Signal: BUY (crossed or dipped market)\n");
        send_order_to_alpaca("buy");
    } else if (signal == 2) {
        printf(">>> [FPGA] Signal: SELL (spiked market)\n");
        send_order_to_alpaca("sell");
    } else if (signal != 0) {
        printf(">>> [FPGA] Unknown signal value %u\n", signal);
    }

    /* Handshake: clear the signal so the same decision is not executed
     * twice. The CPU re-raises it if the condition persists. */
    if (signal != 0) fpga_regs[WORD_SIGNAL] = 0;
}

/* ------------------------------------------------------------------ */
/* Coinbase WebSocket feed                                             */
/* ------------------------------------------------------------------ */

static void process_market_message(char *data) {
    if (get_time_ms() - last_process_time < THROTTLE_MS) return;

    /* Minimal manual JSON extraction (match messages only) */
    char *price_ptr = strstr(data, "\"price\":\"");
    char *size_ptr  = strstr(data, "\"size\":\"");
    char *side_ptr  = strstr(data, "\"side\":\"");

    const char *side_str = "unknown";
    const char *side_val = NULL;

    if (side_ptr) {
        side_val = side_ptr + 8;   /* points at 'b' or 's' */
        if (*side_val == 'b' || *side_val == 'B') side_str = "buy";
        else if (*side_val == 's' || *side_val == 'S') side_str = "sell";
    }

    if (price_ptr && size_ptr && side_val) {
        float price = strtof(price_ptr + 9, NULL);
        float size  = strtof(size_ptr + 8, NULL);

        /* Fixed-point for the CPU: price x 10000 keeps 4 decimals */
        unsigned int price_int = (unsigned int)(price * 10000.0f);
        unsigned int size_int  = (unsigned int)(size);

        printf("[MARKET] $%.2f x %.4f (%s) -> FPGA\n", price, size, side_str);

        update_fpga_input(price_int, size_int, side_val);
        check_fpga_decision();
        last_process_time = get_time_ms();
    }
}

static void coinbase_cb(struct mg_connection *c, int ev, void *ev_data) {
    if (ev == MG_EV_CONNECT) {
        struct mg_tls_opts opts = {
            .ca   = mg_str(""),
            .name = mg_str("ws-feed.exchange.coinbase.com")
        };
        mg_tls_init(c, &opts);
    } else if (ev == MG_EV_WS_OPEN) {
        printf("Connected to Coinbase, subscribing to BTC-USD matches...\n");
        mg_ws_send(c, s_sub_msg, strlen(s_sub_msg), WEBSOCKET_OP_TEXT);
    } else if (ev == MG_EV_WS_MSG) {
        struct mg_ws_message *wm = (struct mg_ws_message *) ev_data;
        char *tmp = (char *) malloc(wm->data.len + 1);
        if (!tmp) return;
        memcpy(tmp, wm->data.buf, wm->data.len);
        tmp[wm->data.len] = '\0';
        if (strstr(tmp, "\"match\"")) {
            process_market_message(tmp);
        }
        free(tmp);
    }
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("--- FMMA: Coinbase -> FPGA -> Alpaca ---\n");
    printf("Shared RAM at 0x%X: BUY=%d SELL=%d SIGNAL=%d BEAT=%d\n",
           (unsigned) LW_H2F_BASE, WORD_BUY_PRICE, WORD_SELL_PRICE,
           WORD_SIGNAL, WORD_HEARTBEAT);

    s_alpaca_key    = getenv("APCA_API_KEY_ID");
    s_alpaca_secret = getenv("APCA_API_SECRET_KEY");
    if (!s_alpaca_key || !s_alpaca_secret)
        printf("NOTE: Alpaca keys not in environment, orders will be skipped.\n");

    /* Map the lightweight HPS-to-FPGA bridge window */
    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd == -1) {
        printf("CRITICAL: could not open /dev/mem (run with sudo).\n");
        printf("Entering SIMULATION MODE (no FPGA I/O).\n");
    } else {
        void *map_base = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE,
                              MAP_SHARED, mem_fd, LW_H2F_BASE);
        if (map_base == MAP_FAILED) {
            printf("MMAP of 0x%X failed - is the hps_0 bridge in the device tree?\n",
                   (unsigned) LW_H2F_BASE);
            close(mem_fd);
            mem_fd = -1;
        } else {
            fpga_regs = (volatile unsigned int *) map_base;
            printf("Lightweight bridge mapped at 0x%X\n", (unsigned) LW_H2F_BASE);
            if (load_fpga_program() == 0)
                wait_for_cpu();
        }
    }

    /* Network loop */
    mg_mgr_init(&mgr);
    mg_log_set(0);
    mg_ws_connect(&mgr, s_coinbase_url, coinbase_cb, NULL, NULL);

    while (1) {
        mg_mgr_poll(&mgr, 100);
        if (fpga_regs) check_fpga_decision();   /* act even if the feed is quiet */
    }

    mg_mgr_free(&mgr);
    return 0;
}
