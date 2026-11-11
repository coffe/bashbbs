/* ae_transport_bashbbs.c - runs the LiveChat68 door on a BashBBS terminal.
 *
 * LiveChat68 reaches its board through the small API in aedoor.h. This file
 * implements that API over the caller's terminal, in place of the Amiga
 * transport. The door itself is built unchanged.
 *
 * Who is calling comes from the environment, set by lib/menu.sh:
 *   BBS_DOOR_USER   the handle shown in chat
 *   BBS_DOOR_LEVEL  255 for the sysop, which enables the setup screen
 *
 * The door thinks in Latin-1, one byte per screen cell, and BashBBS terminals
 * are UTF-8. Output is converted on the way out and keys on the way in, so
 * the door's cell arithmetic stays true.
 */
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "aedoor.h"
#include "ae_session.h"

#define NO_BYTE (-2)
#define CARRIER_LOST (-1)

static struct termios saved_tty;
static volatile sig_atomic_t tty_is_raw;
static int carrier_lost;
static int pushed_back = NO_BYTE;

/* Only async-signal-safe calls: this also runs from the signal handler. */
static void restore_terminal(void)
{
    static const char reset[] = "\033[0m\033[?25h";

    if (!tty_is_raw) return;
    tty_is_raw = 0;
    if (write(STDOUT_FILENO, reset, sizeof reset - 1) < 0) carrier_lost = 1;
    tcsetattr(STDIN_FILENO, TCSANOW, &saved_tty);
}

static void on_hangup(int sig)
{
    restore_terminal();
    _exit(128 + sig);
}

int ae_start(int node)
{
    struct termios raw;

    (void)node;
    signal(SIGPIPE, SIG_IGN);       /* a dropped TLS socket must not kill us */
    signal(SIGHUP, on_hangup);
    signal(SIGTERM, on_hangup);

    if (tcgetattr(STDIN_FILENO, &saved_tty) == 0) {
        raw = saved_tty;
        raw.c_lflag &= (tcflag_t)~(ICANON | ECHO | ISIG | IEXTEN);
        raw.c_iflag &= (tcflag_t)~(ICRNL | IXON | INLCR | IGNCR);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;
        if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0) {
            tty_is_raw = 1;
            atexit(restore_terminal);
        }
    }
    return 0;
}

static void write_all(const char *p, size_t n)
{
    ssize_t done;

    while (n > 0 && !carrier_lost) {
        done = write(STDOUT_FILENO, p, n);
        if (done < 0) {
            if (errno == EINTR) continue;
            carrier_lost = 1;
            return;
        }
        p += done;
        n -= (size_t)done;
    }
}

void ae_put(const char *text, int newline)
{
    char out[4096];
    size_t used = 0;
    unsigned char c;

    if (text == NULL) text = "";
    for (; *text != '\0'; text++) {
        if (used > sizeof out - 2) {
            write_all(out, used);
            used = 0;
        }
        c = (unsigned char)*text;
        if (c < 0x80) {
            out[used++] = (char)c;
        } else {
            out[used++] = (char)(0xC0 | (c >> 6));
            out[used++] = (char)(0x80 | (c & 0x3F));
        }
    }
    if (newline) {
        if (used > sizeof out - 2) {
            write_all(out, used);
            used = 0;
        }
        out[used++] = '\n';
    }
    write_all(out, used);
}

/* Waits up to timeout_ms. Returns 1 when a read will not block, else 0. */
static int input_ready(int timeout_ms)
{
    struct pollfd p;

    p.fd = STDIN_FILENO;
    p.events = POLLIN;
    p.revents = 0;
    return poll(&p, 1, timeout_ms) > 0;
}

/* One raw byte, or CARRIER_LOST at end of input or on a dead terminal. */
static int read_byte(void)
{
    unsigned char b;
    ssize_t got;

    for (;;) {
        got = read(STDIN_FILENO, &b, 1);
        if (got == 1) return b;
        if (got < 0 && errno == EINTR) continue;
        carrier_lost = 1;
        return CARRIER_LOST;
    }
}

/* One key as a Latin-1 byte. Characters Latin-1 cannot hold read as '?'. */
static int read_key(void)
{
    int lead = read_byte();
    int extra;
    int b;
    int value;

    if (lead < 0x80) return lead;       /* ASCII, or CARRIER_LOST */
    if (lead < 0xC2) return '?';        /* stray continuation byte */
    extra = lead < 0xE0 ? 1 : lead < 0xF0 ? 2 : 3;
    value = lead & 0x1F;
    while (extra-- > 0) {
        if (!input_ready(50)) return '?';
        b = read_byte();
        if (b == CARRIER_LOST) return CARRIER_LOST;
        value = (value << 6) | (b & 0x3F);
    }
    return (lead < 0xC4 && value <= 0xFF) ? value : '?';
}

int ae_input_pending(void)
{
    if (pushed_back != NO_BYTE || carrier_lost) return 1;
    if (!input_ready(40)) return 0;
    pushed_back = read_key();
    return 1;
}

int ae_key(void)
{
    int k;

    if (pushed_back != NO_BYTE) {
        k = pushed_back;
        pushed_back = NO_BYTE;
        return k;
    }
    if (carrier_lost) return CARRIER_LOST;
    return read_key();
}

void ae_get(char *buf, int maxlen)
{
    int used = 0;
    int k;

    if (buf == NULL || maxlen <= 0) return;
    while ((k = ae_key()) != CARRIER_LOST && k != '\r' && k != '\n') {
        if (used < maxlen - 1) buf[used++] = (char)k;
    }
    buf[used] = '\0';
}

void ae_delay_ticks(int ticks)
{
    struct timespec t;

    if (ticks <= 0) return;
    t.tv_sec = ticks / 50;
    t.tv_nsec = (long)(ticks % 50) * 20000000L;
    while (nanosleep(&t, &t) < 0 && errno == EINTR) {
    }
}

int ae_check(void)
{
    return carrier_lost;
}

void ae_raw_arrows(int on)
{
    (void)on;                   /* terminals send escape sequences anyway */
}

void ae_return_command(const char *command)
{
    (void)command;              /* BashBBS has no command to return to */
}

void ae_shutdown(void)
{
    restore_terminal();
}

void ae_fatal(int code)
{
    restore_terminal();
    exit(code);
}

static int answer(char *out, int cap, const char *value)
{
    size_t n = strlen(value);

    if (n >= (size_t)cap) n = (size_t)cap - 1;
    memcpy(out, value, n);
    out[n] = '\0';
    return (int)n;
}

static int answer_number(char *out, int cap, int value)
{
    char text[16];

    snprintf(text, sizeof text, "%d", value);
    return answer(out, cap, text);
}

int ae_field_read(int field, char *out, int cap)
{
    struct winsize ws;
    const char *v;

    if (out == NULL || cap <= 0) return -1;
    out[0] = '\0';
    if (carrier_lost) return -1;

    switch (field) {
    case AE_FIELD_USER_NAME:
        v = getenv("BBS_DOOR_USER");
        return answer(out, cap, v != NULL ? v : "guest");
    case AE_FIELD_USER_LEVEL:
        v = getenv("BBS_DOOR_LEVEL");
        return answer(out, cap, v != NULL ? v : "1");
    case AE_FIELD_IS_ANSI:
        return answer(out, cap, "1");
    case AE_FIELD_SCREEN_COLS:
    case AE_FIELD_SCREEN_ROWS:
        if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) != 0 || ws.ws_col == 0 || ws.ws_row == 0) return 0;
        return answer_number(out, cap, field == AE_FIELD_SCREEN_COLS ? ws.ws_col : ws.ws_row);
    default:
        return 0;               /* a field this board does not offer */
    }
}

int ae_field_write(int field, const char *value)
{
    (void)field;
    (void)value;
    return 0;
}

int ae_query_bit(int acs)
{
    (void)acs;
    return 0;
}

/* A classic board echoes a query it does not know, which the door reads as
 * "this feature is not here". */
int ae_field_exchange(int field, const char *request, char *out, int cap)
{
    (void)field;
    if (out == NULL || cap <= 0) return -1;
    return answer(out, cap, request != NULL ? request : "");
}
