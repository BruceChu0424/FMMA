#include "mongoose.h" 
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

// Configuration

// Coinbase (Input)
static const char *s_coinbase_url = "wss://ws-feed.exchange.coinbase.com";
static const char *s_sub_msg =
    "{\"type\":\"subscribe\",\"product_ids\":[\"BTC-USD\"],\"channels\":[\"matches\"]}";

// Alpaca (Output)
static const char *s_alpaca_url   = "https://paper-api.alpaca.markets/v2/orders";
static const char *s_alpaca_host  = "paper-api.alpaca.markets"; 
static const char *s_alpaca_key   = "PKxxxxxxxxxxxxxxxxxx";      // <--- Put Alpaca Key Here
static const char *s_alpaca_secret= "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; // <--- Put Alpaca Secret Here

// FPGA Memory Map (HPS-to-FPGA Bridge)
// NOTE: Make sure this base address matches your Qsys/Platform Designer address map
#define LWH2F_BASE     0xC8000000   // Check if this should be 0xFF200000 for LW bridge on DE1-SoC
#define MAP_SIZE       4096
#define BRAM_OFFSET    0

// Offsets in 32-bit WORDS (fpga_regs[index] = base + index * 4 bytes)
#define REG_BUY_PRICE_OFFSET     16   // Buy price register 0x40 (d'64
#define REG_SELL_PRICE_OFFSET    17   // Sell price register 0x44 (d'68)
#define REG_SIGNAL_OFFSET        18   // FPGA -> HPS signal register 0x48 (d'72)
// 19 free
#define REG_BUY_SIZE_OFFSET      20   // Buy size register 0x50 (d'80)
#define REG_SELL_SIZE_OFFSET     21   // Sell size register 0x54 (d'84)

// Throttle Constants (TRADE_COOLDOWN_MS cannot be smaller than 500, else the trades will be "too fast" and will ban the user)
#define THROTTLE_MS        200
#define TRADE_COOLDOWN_MS 1000

// Global Variables
volatile unsigned int *fpga_regs = NULL; // Pointer to FPGA memory
int mem_fd = -1;
unsigned long last_process_time = 0;
unsigned long last_trade_time   = 0;
struct mg_mgr mgr;

// Helper Function to get time in ms
unsigned long get_time_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long)(ts.tv_sec * 1000) + (unsigned long)(ts.tv_nsec / 1000000);
}

// Alpaca Execution
static void alpaca_cb(struct mg_connection *c, int ev, void *ev_data) {
    if (ev == MG_EV_CONNECT) {
        // TLS Handshake for Alpaca
        struct mg_tls_opts opts = {
            .ca   = mg_str(""),
            .name = mg_str(s_alpaca_host) // SNI is critical for Alpaca
        };
        mg_tls_init(c, &opts);
    } 
    else if (ev == MG_EV_HTTP_MSG) {
        struct mg_http_message *hm = (struct mg_http_message *)ev_data;
        printf("[ALPACA] Response: %.*s\n", (int)hm->message.len, hm->message.buf);
        c->is_draining = 1; // Close connection after response
    }
}

void send_order_to_alpaca(const char *side) {
    unsigned long now = get_time_ms();
    if (now - last_trade_time < TRADE_COOLDOWN_MS) {
        printf("[EXECUTION] Cooldown active. Ignoring %s signal.\n", side);
        return;
    }

    printf("⚡ [EXECUTION] Sending %s order to Alpaca...\n", side);
    
    struct mg_connection *c = mg_http_connect(&mgr, s_alpaca_url, alpaca_cb, NULL);
    if (!c) {
        printf("[EXECUTION] Failed to create connection.\n");
        return;
    }

    // Build JSON Payload
    char body[256];
    snprintf(body, sizeof(body), 
             "{\"symbol\":\"BTCUSD\",\"qty\":\"0.001\",\"side\":\"%s\","
             "\"type\":\"market\",\"time_in_force\":\"gtc\"}", 
             side);

    // Send HTTP Request
    mg_printf(c, 
        "POST /v2/orders HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "APCA-API-KEY-ID: %s\r\n"
        "APCA-API-SECRET-KEY: %s\r\n"
        "\r\n"
        "%s", 
        s_alpaca_host, (int)strlen(body), s_alpaca_key, s_alpaca_secret, body);

    last_trade_time = now;
}

// FPGA Communication
void update_fpga_input(unsigned int price, unsigned int size, const char *side) {
    if (!fpga_regs || !side) return;

    char c = side[0];  // first character: 'b' or 's'
    if (c == 'b' || c == 'B') {
        // BUY side
        fpga_regs[REG_BUY_PRICE_OFFSET] = price;
        fpga_regs[REG_BUY_SIZE_OFFSET]  = size;
        printf("[FPGA] BUY -> price=%u (reg %d), size=%u (reg %d)\n",
               price, REG_BUY_PRICE_OFFSET, size, REG_BUY_SIZE_OFFSET);
    } else if (c == 's' || c == 'S') {
        // SELL side
        fpga_regs[REG_SELL_PRICE_OFFSET] = price;
        fpga_regs[REG_SELL_SIZE_OFFSET]  = size;
        printf("[FPGA] SELL -> price=%u (reg %d), size=%u (reg %d)\n",
               price, REG_SELL_PRICE_OFFSET, size, REG_SELL_SIZE_OFFSET);
    } else {
        // Unknown side
        printf("[FPGA] Unknown side '%c' – ignoring\n", c);
    }
}

void check_fpga_decision() {
    if (!fpga_regs) return;

    // Read the Signal Register (REG_SIGNAL_OFFSET)
    unsigned int signal = fpga_regs[REG_SIGNAL_OFFSET];

    if (signal != 0) {
        // 1 = BUY, 2 = SELL (example)
        if (signal == 1) {
            printf("💡 [FPGA] Signal Detected: BUY (1)\n");
            // TODO: send_order_to_alpaca("buy");
        } else if (signal == 2) {
            printf("💡 [FPGA] Signal Detected: SELL (2)\n");
            // TODO: send_order_to_alpaca("sell");
        } else {
            printf("💡 [FPGA] Signal Detected: UNKNOWN (%u)\n", signal);
        }

        // HANDSHAKE: Clear the register to 0 so we don't trade again immediately
        fpga_regs[REG_SIGNAL_OFFSET] = 0;
    } else {
        // Optional: comment this out if it's too spammy
        // printf("Waiting for FPGA....\n");
    }
}

// Coinbase Parser
void process_market_message(char *data) {
    if (get_time_ms() - last_process_time < THROTTLE_MS) return;

    // Manual JSON Parsing
    char *price_ptr = strstr(data, "\"price\":\"");
    char *size_ptr  = strstr(data, "\"size\":\"");
    char *side_ptr  = strstr(data, "\"side\":\"");

    const char *side_str = "unknown";
    const char *side_val = NULL;

    if (side_ptr) {
        side_val = side_ptr + 8;  // points to 'b' in "buy" or 's' in "sell"
        if (*side_val == 'b' || *side_val == 'B') side_str = "buy";
        else if (*side_val == 's' || *side_val == 'S') side_str = "sell";
    }
  
    if (price_ptr && size_ptr && side_val) {
        float price = strtof(price_ptr + 9, NULL);
        float size  = strtof(size_ptr + 8, NULL);

        // Scale to Integers for FPGA (×10000 for price precision)
        unsigned int price_int = (unsigned int)(price * 10000.0f);
        unsigned int size_int  = (unsigned int)(size);

        // MARKET DATA TEST
        printf("Price_int = %u\n", price_int);
        printf("Size_int  = %u\n", size_int);
        printf("Side      = %s\n", side_str);

        // Send Data + side to FPGA
        update_fpga_input(price_int, size_int, side_val);

        // Check FPGA for Decision
        check_fpga_decision();

        // Debug Print (Optional)
        printf("[MARKET] $%.2f -> FPGA\n", price);
        
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
    } 
    else if (ev == MG_EV_WS_OPEN) {
        printf("Connected to Coinbase! Subscribing...\n");
        mg_ws_send(c, s_sub_msg, strlen(s_sub_msg), WEBSOCKET_OP_TEXT);
    } 
    else if (ev == MG_EV_WS_MSG) {
        struct mg_ws_message *wm = (struct mg_ws_message *)ev_data;
        char *tmp = (char *)malloc(wm->data.len + 1);
        if (!tmp) return;

        memcpy(tmp, wm->data.buf, wm->data.len); 
        tmp[wm->data.len] = '\0';
        
        if (strstr(tmp, "\"match\"")) {
            process_market_message(tmp);
        }
        free(tmp);
    }
}

int main(void) {
    // Initialize Memory Mapping
    mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd == -1) {
        printf("CRITICAL: Could not open /dev/mem. Run with sudo.\n");
        printf("Entering SIMULATION MODE (No Hardware I/O)\n");
    } else {
        void *map_base = mmap(NULL, MAP_SIZE,
                              PROT_READ | PROT_WRITE,
                              MAP_SHARED, mem_fd, LWH2F_BASE);
        if (map_base == MAP_FAILED) {
            printf("MMAP Failed.\n");
        } else {
            fpga_regs = (volatile unsigned int *)((char *)map_base + BRAM_OFFSET);
            printf("Hardware Bridge Active at 0x%X\n", LWH2F_BASE);
        }
    }

    // Start Network Loop
    mg_mgr_init(&mgr);
    mg_log_set(0);
    
    printf("--- C High-Frequency Trading System ---\n");
    printf("--- Coinbase -> FPGA -> Alpaca ---\n\n");

    mg_ws_connect(&mgr, s_coinbase_url, coinbase_cb, NULL, NULL);

    while (1) {
        mg_mgr_poll(&mgr, 100); // 100ms poll rate
        
        // Also check FPGA decision here in case WS is quiet
        if (fpga_regs) check_fpga_decision();
    }

    mg_mgr_free(&mgr);
    return 0;
}
