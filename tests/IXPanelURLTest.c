#include <stdio.h>
#include <string.h>

#include "../src/Backend/IXPanelURL.h"

static int g_failed = 0;

static void expect(int cond, const char *name) {
    if (cond) {
        printf("ok %s\n", name);
        return;
    }
    printf("FAIL %s\n", name);
    g_failed++;
}

static void expect_str(const char *got, const char *want, const char *name) {
    expect(got && want && strcmp(got, want) == 0, name);
    if (got && want && strcmp(got, want) != 0) printf("  got [%s] want [%s]\n", got, want);
}

int main(void) {
    char out[256];
    expect(IXPanelHostNeedsPin("zovidar.duckdns.org") == 0, "named host uses system trust");
    expect(IXPanelHostNeedsPin("77.110.125.217") == 1, "ip fallback is pinned");
    expect(IXPanelHostNeedsPin(NULL) == 0, "missing host is not pinned");
    expect(IXPanelHostNeedsPin("") == 0, "empty host is not pinned");
    expect(IXPanelHostNeedsPin("evil.example") == 0, "other host is not pinned");

    expect(IXPanelJoinURL("https://zovidar.duckdns.org", "/static/fonts/abc.ttf", out, sizeof out) == 1, "font join");
    expect_str(out, "https://zovidar.duckdns.org/static/fonts/abc.ttf", "font url");
    expect(IXPanelJoinURL("https://zovidar.duckdns.org/", "/api/v1/register", out, sizeof out) == 1, "trailing slash");
    expect_str(out, "https://zovidar.duckdns.org/api/v1/register", "register url");
    expect(IXPanelJoinURL("https://77.110.125.217:9443", "/static/stickers/abc.png", out, sizeof out) == 1, "fallback sticker");
    expect_str(out, "https://77.110.125.217:9443/static/stickers/abc.png", "fallback sticker url");
    expect(IXPanelJoinURL("https://zovidar.duckdns.org", "static/fonts/abc.ttf", out, sizeof out) == 1, "missing slash");
    expect_str(out, "https://zovidar.duckdns.org/static/fonts/abc.ttf", "missing slash url");
    expect(IXPanelJoinURL("https://zovidar.duckdns.org", "/static/fonts/../x.ttf", out, sizeof out) == 0, "dotdot rejected");
    expect(IXPanelJoinURL("https://zovidar.duckdns.org", "https://evil/x", out, sizeof out) == 0, "scheme rejected");

    expect(IXPanelStaticPath("/static/fonts/abc.ttf", out, sizeof out) == 1, "relative font");
    expect_str(out, "/static/fonts/abc.ttf", "relative font path");
    expect(IXPanelStaticPath("/static/stickers/abc.png", out, sizeof out) == 1, "relative sticker");
    expect_str(out, "/static/stickers/abc.png", "relative sticker path");
    expect(IXPanelStaticPath("https://zovidar.duckdns.org/static/fonts/abc.ttf", out, sizeof out) == 1, "absolute primary");
    expect_str(out, "/static/fonts/abc.ttf", "absolute primary path");
    expect(IXPanelStaticPath("https://77.110.125.217:9443/static/stickers/abc.png", out, sizeof out) == 1, "absolute fallback");
    expect_str(out, "/static/stickers/abc.png", "absolute fallback path");
    expect(IXPanelStaticPath("https://evil.example/static/fonts/abc.ttf", out, sizeof out) == 0, "other host rejected");
    expect(IXPanelStaticPath("/static/fonts/../abc.ttf", out, sizeof out) == 0, "static dotdot rejected");
    expect(IXPanelStaticPath("/static/fonts/abc.ttf?x=1", out, sizeof out) == 0, "query rejected");
    expect(IXPanelStaticPath("/api/v1/config", out, sizeof out) == 0, "api path is not an asset");
    expect(IXPanelStaticPath("/static/fonts/", out, sizeof out) == 0, "empty file rejected");
    return g_failed ? 1 : 0;
}
