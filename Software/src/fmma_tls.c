#include "fmma_tls.h"
#include "fmma_log.h"

#include "../third_party/mongoose.h"

#include <string.h>
#include <unistd.h>

#define TAG "tls"

static const char *s_override;

static const char *k_candidates[] = {
    "/etc/ssl/certs/ca-certificates.crt",   /* Debian, Ubuntu           */
    "/etc/pki/tls/certs/ca-bundle.crt",     /* Fedora, RHEL             */
    "/etc/ssl/cert.pem",                    /* Alpine, BSD              */
    "/usr/local/share/certs/ca-root-nss.crt",
    NULL
};

void fmma_tls_set_ca_file(const char *path) { s_override = path; }

const char *fmma_tls_ca_file(void)
{
    if (s_override) return s_override;
    for (int i = 0; k_candidates[i]; i++)
        if (access(k_candidates[i], R_OK) == 0) return k_candidates[i];
    return NULL;
}

void fmma_tls_check(void)
{
    const char *ca = fmma_tls_ca_file();
    if (ca) {
        FMMA_INFO(TAG, "verifying certificates against %s", ca);
    } else {
        FMMA_WARN(TAG, "no CA bundle found: certificates cannot be verified");
        FMMA_WARN(TAG, "install ca-certificates, or pass --ca /path/to/bundle");
    }
}

void fmma_tls_start(struct mg_connection *c, const char *host)
{
    struct mg_tls_opts opts;
    memset(&opts, 0, sizeof(opts));

    const char *ca = fmma_tls_ca_file();
    if (ca) opts.ca = mg_file_read(&mg_fs_posix, ca);
    opts.name = mg_str(host);          /* SNI; both endpoints require it */

    mg_tls_init(c, &opts);
}
