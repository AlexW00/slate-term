// Research fixture only: exercises an existing VT library, not a Slate feature.
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

static GhosttyTerminal create(void) {
    GhosttyTerminal t;
    assert(ghostty_terminal_new(NULL, &t, 80, 24) == GHOSTTY_SUCCESS);
    return t;
}
static void feed(GhosttyTerminal t, const char *s) {
    ghostty_terminal_vt_write(t, (const uint8_t *)s, strlen(s));
}
static void snapshot(GhosttyTerminal t, char *buffer, size_t capacity) {
    GhosttyFormatterTerminalOptions opts = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    opts.trim = true;
    opts.unwrap = true;
    GhosttyFormatter f;
    assert(ghostty_formatter_terminal_new(NULL, &f, t, opts) == GHOSTTY_SUCCESS);
    size_t written = 0;
    assert(ghostty_formatter_format_buf(f, (uint8_t *)buffer, capacity - 1, &written) == GHOSTTY_SUCCESS);
    buffer[written] = 0;
    ghostty_formatter_free(f);
}
int main(void) {
    GhosttyString version;
    assert(ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_STRING, &version) == GHOSTTY_SUCCESS);
    printf("Library-reported version: %.*s\n", (int)version.len, version.ptr);
    char text[8192];
    GhosttyTerminal t = create();
    feed(t, "PROBE welcome\r\n");
    feed(t, "shell> ");
    snapshot(t, text, sizeof text);
    assert(strstr(text, "PROBE welcome\nshell>") != NULL);
    puts("PASS: sequential CRLF output precedes shell text");
    feed(t, "\033[2J\033[H");
    feed(t, "shell> ");
    snapshot(t, text, sizeof text);
    assert(strstr(text, "PROBE welcome") == NULL);
    puts("PASS: clear/home removes welcome from current screen");
    ghostty_terminal_free(t);

    t = create();
    feed(t, "ABC\nX");
    snapshot(t, text, sizeof text);
    assert(strstr(text, "ABC\n   X") != NULL);
    puts("PASS: bare LF does not reset column; CRLF is needed for direct output");
    ghostty_terminal_free(t);

    t = create();
    feed(t, "\033["); // Child's partial CSI, before an ill-timed synthetic write.
    feed(t, "WELCOME\r\n");
    feed(t, "0mchild");
    snapshot(t, text, sizeof text);
    assert(strstr(text, "WELCOME") == NULL);
    puts("PASS: injecting between parts of a VT sequence corrupts intended text");
    ghostty_terminal_free(t);

    t = create();
    const char *utf8 = "PROBE → ⌘K 日本語\r\n";
    for (size_t i = 0; i < strlen(utf8); ++i)
        ghostty_terminal_vt_write(t, (const uint8_t *)utf8 + i, 1);
    snapshot(t, text, sizeof text);
    assert(strstr(text, "PROBE → ⌘K 日本語") != NULL);
    puts("PASS: UTF-8 output survives byte-at-a-time feeding");
    ghostty_terminal_free(t);
    return 0;
}
