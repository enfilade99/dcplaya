/**
 * @ingroup  exe_plugin
 * @file     chat.c
 * @brief    DC99 chat : IRC #dc99 (live) and KosNet global chat.
 *
 * Ported from the DC99 DreamHub app (irc99.c and the CHAT tab).
 * Everything that waits on the network runs in its own thread, so the
 * music and the screen never stop. The Lua side asks for the news with
 * chat_poll() every frame and draws it.
 *
 *  - IRC : one thread per connection. It looks the server up, connects,
 *    logs in (same conventions as the dc99.net web client : PASS
 *    nick:password, NickServ REGISTER, CAP batch / message-tags /
 *    chathistory / server-time, DC99COLOR name colours, +typing, the hidden
 *    dc99status bot) and then reads and writes the socket.
 *  - KosNet : one worker thread talks plain HTTP/1.0 to
 *    http://dc99.net/online/app.php (s=chat, s=klogin, s=ksay).
 *
 * Network rules learnt on real consoles : plain HTTP, ASCII only, never
 * bind() before connect(), DNS gets several tries and then public DNS.
 */

#include <kos.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ctype.h>

#include "luashell.h"
#include "lwip/lwip.h"
#include "lwip/sockets.h"

extern struct sockaddr_in dnssrv;	/* net_driver.c : set by net_resolv */

#define IRC_CHAN "#dc99"
#define IRC_BOT  "dc99status"

/* ------------------------------------------------------------------------
 * small helpers
 * ---------------------------------------------------------------------- */

static uint32 ms_now(void)
{
  return (uint32)timer_ms_gettime64();
}

static int ieq(const char *a, const char *b)
{
  while (*a && *b) {
    int x = *a++, y = *b++;
    if (x >= 'A' && x <= 'Z') x += 32;
    if (y >= 'A' && y <= 'Z') y += 32;
    if (x != y) return 0;
  }
  return *a == *b;
}

/* overlapping copy, by hand (the program's memmove is not to be trusted
   with overlapping blocks here) */
static void mv(void *d, const void *s, int n)
{
  char *a = d;
  const char *b = s;
  if (a < b)
    while (n-- > 0) *a++ = *b++;
  else {
    a += n; b += n;
    while (n-- > 0) *--a = *--b;
  }
}

/* (no ctype.h tests : the program's character table is not reliable) */
static int is_digit(int c) { return c >= '0' && c <= '9'; }
static int is_alnum(int c)
{
  return is_digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}
static int lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }

static int ncase(const char *a, const char *b, int n)
{
  for (; n > 0; n--, a++, b++) {
    int x = lower((unsigned char)*a), y = lower((unsigned char)*b);
    if (x != y) return x - y;
    if (!x) return 0;
  }
  return 0;
}

static int icase(const char *a, const char *b)
{
  return ncase(a, b, 0x7fffffff);
}

static void cpy(char *d, const char *s, int n)
{
  if (!s) s = "";
  strncpy(d, s, n - 1);
  d[n - 1] = 0;
}

/* send all of it ; 0 if ok */
static int send_all(int s, const char *b, int n)
{
  while (n > 0) {
    int k = send(s, b, n, 0);
    if (k <= 0)
      return -1;
    b += k;
    n -= k;
  }
  return 0;
}

/* wait until s can be read (data, or closed), at most ms milliseconds ;
   1 if it can. Polls with thd_sleep : this lwIP's select() did not give up
   at its time limit, and that froze things on real consoles. */
int lwip_dc99_pending(int fd);	/* kossockets.c (patched) */

static int wait_read(int s, int ms)
{
  for (;;) {
    int p = lwip_dc99_pending(s);
    if (p != 0)
      return 1;
    if (ms <= 0)
      return 0;
    thd_sleep(20);
    ms -= 20;
  }
}

/* ------------------------------------------------------------------------
 * DNS : the server set in the network settings (three tries), then
 * 1.1.1.1 and 8.8.8.8. Names that worked are remembered.
 * ---------------------------------------------------------------------- */

static struct { char name[48]; uint32 addr; } dns_cache[4];
static int dns_next;

static int dns_parse_ip(const char *name, uint32 *out)
{
  unsigned v[4];
  int i = 0, d = 0;
  v[0] = v[1] = v[2] = v[3] = 0;
  for (; *name; name++) {	/* (no sscanf : this libc's one is not safe) */
    if (*name >= '0' && *name <= '9') {
      v[i] = v[i] * 10 + (*name - '0');
      if (v[i] > 255 || ++d > 3) return -1;
    } else if (*name == '.' && d && i < 3) {
      i++;
      d = 0;
    } else
      return -1;
  }
  if (i != 3 || !d)
    return -1;
  *out = htonl((v[0] << 24) | (v[1] << 16) | (v[2] << 8) | v[3]);
  return 0;
}

static mutex_t *dnsm;		/* one lookup at a time (shared buffers) */

static int dns_ask(uint32 server, const char *name, uint32 *out, int ms)
{
  static uint8 q[300];
  int o, ls, i, s, n, an, qd;
  struct sockaddr_in to;
  static uint16 id = 0x4499;

  if (strlen(name) > 200)
    return -1;
  memset(q, 0, 12);
  ++id;
  q[0] = id >> 8; q[1] = id;
  q[2] = 0x01;			/* recursion desired */
  q[5] = 0x01;			/* one question */
  ls = 12; o = 13;
  for (i = 0; ; i++) {
    if (name[i] == '.' || name[i] == 0) {
      q[ls] = o - ls - 1;
      ls = o++;
      if (!name[i]) break;
    } else
      q[o++] = name[i];
  }
  q[ls] = 0;
  o = ls + 1;
  q[o++] = 0; q[o++] = 1;	/* A  */
  q[o++] = 0; q[o++] = 1;	/* IN */

  s = socket(PF_INET, SOCK_DGRAM, 0);
  if (s < 0)
    return -1;
  memset(&to, 0, sizeof(to));
  to.sin_family = AF_INET;
  to.sin_port = htons(53);
  to.sin_addr.s_addr = server;
  if (sendto(s, q, o, 0, (struct sockaddr *)&to, sizeof(to)) < 0
      || !wait_read(s, ms)) {
    close(s);
    return -1;
  }
  {
    static uint8 r[600];
    n = recv(s, r, sizeof(r), 0);
    close(s);
    if (n < 12 || r[0] != q[0] || r[1] != q[1] || (r[3] & 15))
      return -1;
    qd = (r[4] << 8) | r[5];
    an = (r[6] << 8) | r[7];
    o = 12;
    while (qd-- > 0) {		/* skip the questions */
      while (o < n && r[o]) {
	if ((r[o] & 0xc0) == 0xc0) { o++; break; }
	o += r[o] + 1;
      }
      o += 5;
    }
    while (an-- > 0 && o < n) {
      int type, len;
      if ((r[o] & 0xc0) == 0xc0)
	o += 2;
      else {
	while (o < n && r[o]) o += r[o] + 1;
	o++;
      }
      if (o + 10 > n) break;
      type = (r[o] << 8) | r[o + 1];
      len = (r[o + 8] << 8) | r[o + 9];
      o += 10;
      if (type == 1 && len == 4 && o + 4 <= n) {
	memcpy(out, r + o, 4);
	return 0;
      }
      o += len;
    }
  }
  return -1;
}

static int chat_resolve2(const char *name, uint32 *out, char *why, int whyn);

static int chat_resolve(const char *name, uint32 *out, char *why, int whyn)
{
  int r;
  if (!dns_parse_ip(name, out))
    return 0;
  if (!dnsm) dnsm = mutex_create();
  mutex_lock(dnsm);
  r = chat_resolve2(name, out, why, whyn);
  mutex_unlock(dnsm);
  return r;
}

static int chat_resolve2(const char *name, uint32 *out, char *why, int whyn)
{
  int i, k;
  uint32 pub[2];

  for (i = 0; i < 4; i++)
    if (dns_cache[i].addr && ieq(dns_cache[i].name, name)) {
      *out = dns_cache[i].addr;
      return 0;
    }
  dns_parse_ip("1.1.1.1", pub);
  dns_parse_ip("8.8.8.8", pub + 1);
  for (k = 0; k < 5; k++) {
    uint32 srv;
    if (k < 3) {
      if (!dnssrv.sin_port || !dnssrv.sin_addr.s_addr)
	continue;
      srv = dnssrv.sin_addr.s_addr;
    } else
      srv = pub[k - 3];
    if (!dns_ask(srv, name, out, k < 3 ? 2000 : 3000)) {
      cpy(dns_cache[dns_next].name, name, sizeof(dns_cache[0].name));
      dns_cache[dns_next].addr = *out;
      dns_next = (dns_next + 1) & 3;
      return 0;
    }
  }
  snprintf(why, whyn, "Could not find %s (DNS). Check the DNS in "
	   "Network settings.", name);
  return -1;
}

/* test discs only : lines on the serial port once chat_dbg() was called */
static int dbg_on;

static void CDBG(const char *fmt, ...)
{
  static char b[200];
  int n;
  va_list a;
  if (!dbg_on)
    return;
  strcpy(b, "[chat] ");
  va_start(a, fmt);
  n = vsnprintf(b + 7, sizeof(b) - 8, fmt, a);
  va_end(a);
  {
    const char *p = b;
    *(volatile unsigned short*)0xffe80008 |= 0x30;
    while (*p) {
      int k = 100000;
      while (!((*(volatile unsigned short*)0xffe80010) & 0x20) && --k) ;
      *(volatile unsigned char*)0xffe8000c = *p++;
      *(volatile unsigned short*)0xffe80010 &= ~0x60;
    }
  }
}

static int tcp_open(const char *host, int port, char *why, int whyn)
{
  struct sockaddr_in sa;
  uint32 a;
  int s;
  unsigned char *ip;

  CDBG("resolve %s\n", host);
  if (chat_resolve(host, &a, why, whyn))
    return -1;
  CDBG("resolved %08x\n", (unsigned)a);
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons(port);
  sa.sin_addr.s_addr = a;
  ip = (unsigned char *)&a;
  s = socket(PF_INET, SOCK_STREAM, 0);	/* (no bind : connect straight) */
  if (s < 0) {
    snprintf(why, whyn, "No free network socket.");
    return -1;
  }
  CDBG("connect fd %d\n", s);
  if (connect(s, (struct sockaddr *)&sa, sizeof(sa))) {
    CDBG("connect failed\n");
    close(s);
    snprintf(why, whyn, "Could not reach %d.%d.%d.%d port %d.",
	     ip[0], ip[1], ip[2], ip[3], port);
    return -1;
  }
  CDBG("connected\n");
  return s;
}

/* ------------------------------------------------------------------------
 * Events for the Lua side
 * ---------------------------------------------------------------------- */

typedef struct {
  char k;			/* see chat_poll() */
  char mention, hist;
  short hue;
  char conv[32];
  char nick[32];
  char ts[8];
  char text[304];
} chev_t;

/* Memory is short while music plays : the big buffers are only taken
   when the chat is used. */
#define NEV 96
static chev_t *evq;
static int ev_head, ev_n;
static mutex_t *evm;

static void ev_lock(void)   { if (!evm) evm = mutex_create(); mutex_lock(evm); }
static void ev_unlock(void) { mutex_unlock(evm); }

static chev_t ev_spare;

static chev_t *ev_new(int k)	/* call between ev_lock() / ev_unlock() */
{
  chev_t *e;
  if (!evq) {
    evq = malloc(NEV * sizeof(chev_t));
    if (!evq) {
      memset(&ev_spare, 0, sizeof(ev_spare));
      ev_spare.hue = -1;
      return &ev_spare;		/* (dropped) */
    }
  }
  if (ev_n == NEV) {		/* full : forget the oldest */
    ev_head = (ev_head + 1) % NEV;
    ev_n--;
  }
  e = &evq[(ev_head + ev_n++) % NEV];
  memset(e, 0, sizeof(*e));
  e->k = k;
  e->hue = -1;
  return e;
}

static void ev_simple(int k, const char *conv, const char *nick,
		      const char *text)
{
  chev_t *e;
  ev_lock();
  e = ev_new(k);
  cpy(e->conv, conv, sizeof(e->conv));
  cpy(e->nick, nick, sizeof(e->nick));
  cpy(e->text, text, sizeof(e->text));
  ev_unlock();
}

/* ------------------------------------------------------------------------
 * IRC
 * ---------------------------------------------------------------------- */

static struct {
  char host[48];
  int port;
  char nick[32];
  char pass[48];
  int hue;			/* -1 : from the name */
  int ts;			/* 0 : 12 hour, 1 : 24 hour, 2 : off */
  int sys;			/* show joins / parts */
  char ignore[8][24];
} cfg = { "irc.dc99.net", 6667, "", "", -1, 0, 0 };

static volatile int irc_state;	/* 0 off 1 connecting 2 logging in 3 in
				   the channel 4 failed */
static volatile int irc_run, irc_done = 1;
static int irc_fd = -1;
static char irc_err[200], irc_stage[80], irc_me[32];
static int cap_batch, cap_tags, cap_hist, cap_time;
static char hist_ref[4][16];
static int nhist_ref;
static long tz_off, clk_off;	/* zone, and the console clock's exact
				   distance from the server's UTC */
static int tz_known;
static uint32 typing_sent;

static char users[200][24];
static int nusers;
static mutex_t *um;		/* users, hues and typing */
static struct { char nick[24]; int hue; } hues[64];
static int nhues;
static struct { char nick[24]; uint32 until; } typers[6];

/* lines waiting to be sent by the IRC thread */
#define NOUT 12
static char outq[NOUT][440];
static int out_head, out_n;

static void u_lock(void)   { if (!um) um = mutex_create(); mutex_lock(um); }
static void u_unlock(void) { mutex_unlock(um); }

static void irc_send(const char *fmt, ...)
{
  va_list a;
  char *b;
  int n;
  ev_lock();			/* (the out queue shares the event lock) */
  if (out_n == NOUT) {
    ev_unlock();
    return;
  }
  b = outq[(out_head + out_n) % NOUT];
  va_start(a, fmt);
  vsnprintf(b, 430, fmt, a);
  va_end(a);
  b[429] = 0;
  n = strlen(b);
  b[n++] = '\r'; b[n++] = '\n'; b[n] = 0;
  out_n++;
  ev_unlock();
}

static int hash_hue(const char *n)
{
  int32 h = 0;
  for (; *n; n++)
    h = (int32)((uint32)h * 31u + (uint8)*n);
  return (h < 0 ? -h : h) % 360;
}

static int nick_hue(const char *n)	/* call with u_lock */
{
  int i;
  for (i = 0; i < nhues; i++)
    if (ieq(hues[i].nick, n))
      return hues[i].hue;
  return hash_hue(n);
}

static void set_hue(const char *n, int h)	/* call with u_lock */
{
  int i;
  for (i = 0; i < nhues; i++)
    if (ieq(hues[i].nick, n)) {
      if (h < 0) hues[i] = hues[--nhues];
      else hues[i].hue = h;
      return;
    }
  if (h >= 0 && nhues < 64) {
    cpy(hues[nhues].nick, n, 24);
    hues[nhues++].hue = h;
  }
}

static int is_ignored(const char *n)
{
  int i;
  for (i = 0; i < 8; i++)
    if (cfg.ignore[i][0] && ieq(cfg.ignore[i], n))
      return 1;
  return 0;
}

static int is_service(const char *n)
{
  static const char *s[6] = { "nickserv", "chanserv", "operserv",
			      "hostserv", "botserv", "saslserv" };
  int i;
  for (i = 0; i < 6; i++)
    if (ieq(n, s[i]))
      return 1;
  return 0;
}

static long days_from_civil(int y, int m, int d)
{
  long era;
  unsigned yoe, doy, doe;
  y -= m <= 2;
  era = (y >= 0 ? y : y - 399) / 400;
  yoe = (unsigned)(y - era * 400);
  doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (long)doe - 719468;
}

/* "2026-11-17T21:04:05.000Z" -> seconds (UTC) ; 0 if it is not that */
static int num(const char **p, int n)
{
  int v = 0, k;
  for (k = 0; k < n; k++, (*p)++) {
    if (**p < '0' || **p > '9') return -1;
    v = v * 10 + (**p - '0');
  }
  return v;
}

static int iso_time(const char *t, long *utc)
{
  int Y, M, D, h, mi, se;
  if (!t) return 0;
  Y = num(&t, 4); if (Y < 0 || *t++ != '-') return 0;
  M = num(&t, 2); if (M < 0 || *t++ != '-') return 0;
  D = num(&t, 2); if (D < 0 || *t++ != 'T') return 0;
  h = num(&t, 2); if (h < 0 || *t++ != ':') return 0;
  mi = num(&t, 2); if (mi < 0 || *t++ != ':') return 0;
  se = num(&t, 2); if (se < 0) return 0;
  *utc = days_from_civil(Y, M, D) * 86400L + h * 3600L + mi * 60L + se;
  return 1;
}

static void fmt_ts(long t, char *out)
{
  int h = (int)((t / 3600) % 24), m = (int)((t / 60) % 60);
  if (t < 0) { out[0] = 0; return; }
  if (cfg.ts == 2)
    out[0] = 0;
  else if (cfg.ts == 1)
    sprintf(out, "%02d:%02d", h, m);
  else
    sprintf(out, "%d:%02d", h % 12 ? h % 12 : 12, m);
}

static void make_ts(const char *tag_time, char *out)
{
  long utc;
  if (iso_time(tag_time, &utc)) {
    fmt_ts(utc + tz_off, out);
  } else if (tz_known)		/* the server's time, in our zone */
    fmt_ts((long)time(0) - clk_off + tz_off, out);
  else
    fmt_ts((long)time(0), out);
}

/* UTF-8 from IRC -> ASCII. Accents lose their marks, the emoji the web
   client offers become little text faces, anything else is dropped. */
static const unsigned int emoji_cp[] = {
  0x1F600,0x1F603,0x1F604,0x1F601,0x1F606,0x1F605,0x1F602,0x1F923,0x1F60A,
  0x1F642,0x1F609,0x1F60D,0x1F618,0x1F60E,0x1F914,0x1F610,0x1F634,0x1F62E,
  0x1F622,0x1F62D,0x1F621,0x1F631,0x1F61C,0x1F61B,0x1F60F,0x1F643,0x1F44D,
  0x1F44E,0x1F44F,0x1F64C,0x1F64F,0x1F4AA,0x1F44B,0x1F918,0x1F525,0x2764,
  0x1F4AF,0x1F389,0x1F3AE,0x2B50,0x2728,0x1F480,0x1F440,0x1F37A,0x1F355,
  0x1F680,0x1F3C6,0x1F4F7, 0x2665, 0x1F499, 0x1F61D, 0x1F60B, 0x263A,
  0x1F621, 0x1F44C, 0
};
static const char *emoji_txt[] = {
  ":D", ":D", ":D", ":D", "XD", "^^;", ":'D", "XD", "^_^",
  ":)", ";)", "*_*", ":*", "B)", ":-?", ":|", "zzz", ":O",
  ":'(", ";_;", ">:(", "D:", ";P", ":P", ":->", "(:", "(y)",
  "(n)", "*clap*", "\\o/", "*thanks*", "*flex*", "o/", "\\m/", "*fire*", "<3",
  "*100*", "*party*", "*game*", "*star*", "*sparkle*", "*skull*", "*eyes*",
  "*beer*", "*pizza*",
  "*rocket*", "*trophy*", "*camera*", "<3", "<3", "XP", ":P", ":)",
  ">:(", "(ok)", 0
};

static void utf8_in(const char *in, char *out, int max)
{
  static const char *lat =
    "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYPsaaaaaaaceeeeiiiidnooooo/ouuuuypy";
  const unsigned char *p = (const unsigned char *)in;
  int n = 0, i;
  while (*p && n < max - 1) {
    unsigned cp;
    int k;
    if (*p < 0x80) {
      out[n++] = (*p >= 32 || *p == 2 || *p == 1) ? (char)*p : ' ';
      p++;
      continue;
    }
    if (*p < 0xC0) { p++; continue; }
    if (*p >= 0xF0) { cp = *p & 7; k = 3; }
    else if (*p >= 0xE0) { cp = *p & 15; k = 2; }
    else { cp = *p & 31; k = 1; }
    p++;
    while (k-- && (*p & 0xC0) == 0x80)
      cp = (cp << 6) | (*p++ & 63);
    if (cp >= 0xC0 && cp <= 0xFF)
      out[n++] = lat[cp - 0xC0];
    else if (cp == 0xA0)
      out[n++] = ' ';
    else if (cp == 0x2019 || cp == 0x2018)
      out[n++] = '\'';
    else if (cp == 0x201C || cp == 0x201D)
      out[n++] = '"';
    else if (cp == 0x2026) {
      if (n < max - 4) { out[n++] = '.'; out[n++] = '.'; out[n++] = '.'; }
    } else if (cp == 0x2014 || cp == 0x2013)
      out[n++] = '-';
    else if (cp == 0x2022)
      out[n++] = '*';
    else
      for (i = 0; emoji_cp[i]; i++)
	if (emoji_cp[i] == cp) {
	  const char *t = emoji_txt[i];
	  if (n + (int)strlen(t) + 2 < max) {
	    if (n && out[n - 1] != ' ') out[n++] = ' ';
	    while (*t) out[n++] = *t++;
	  }
	  break;
	}
  }
  out[n] = 0;
  /* IRC colour / bold codes : gone */
  {
    char *s = out, *d = out;
    while (*s) {
      if (*s == 3) {
	s++;
	if (is_digit((unsigned char)*s)) s++;
	if (is_digit((unsigned char)*s)) s++;
	if (*s == ',' && is_digit((unsigned char)s[1])) {
	  s += 2;
	  if (is_digit((unsigned char)*s)) s++;
	}
	continue;
      }
      if (*s == 2 || *s == 0x0f || *s == 0x16 || *s == 0x1d || *s == 0x1f) {
	s++;
	continue;
      }
      *d++ = *s++;
    }
    *d = 0;
  }
}

/* a line for the screen */
static void irc_line(int k, const char *conv, const char *nick,
		     const char *text, const char *ttag, int hist)
{
  chev_t *e;
  int hue = -1, mention = 0;
  char t[304];

  utf8_in(text, t, sizeof(t));
  if (nick && *nick) {
    u_lock();
    hue = nick_hue(nick);
    u_unlock();
  }
  if ((k == 'm' || k == 'a') && irc_me[0]) {
    const char *p = t;
    size_t ml = strlen(irc_me);
    while ((p = strstr(p, irc_me))) {	/* (case as typed, like the web) */
      int a = p == t || !is_alnum((unsigned char)p[-1]);
      int b = !is_alnum((unsigned char)p[ml]);
      if (a && b) { mention = 1; break; }
      p += ml;
    }
    if (!mention) {			/* any case */
      int i, n = strlen(t);
      for (i = 0; i + (int)ml <= n; i++)
	if (!ncase(t + i, irc_me, ml)
	    && (i == 0 || !is_alnum((unsigned char)t[i - 1]))
	    && !is_alnum((unsigned char)t[i + ml])) {
	  mention = 1;
	  break;
	}
    }
  }
  ev_lock();
  e = ev_new(k);
  cpy(e->conv, conv ? conv : IRC_CHAN, sizeof(e->conv));
  cpy(e->nick, nick, sizeof(e->nick));
  cpy(e->text, t, sizeof(e->text));
  make_ts(ttag, e->ts);
  e->hue = hue;
  e->mention = mention;
  e->hist = hist;
  ev_unlock();
}

static void sys_line(const char *conv, const char *fmt, ...)
{
  char b[300];
  va_list a;
  va_start(a, fmt);
  vsnprintf(b, sizeof(b), fmt, a);
  va_end(a);
  b[sizeof(b) - 1] = 0;
  irc_line('s', conv, "", b, 0, 0);
}

static void users_changed(void)
{
  ev_simple('u', "", "", "");
}

static int ucmp(const void *a, const void *b)
{
  return icase((const char *)a, (const char *)b);
}

static void user_add(const char *n)
{
  int i;
  if (ieq(n, IRC_BOT) || !*n) return;
  u_lock();
  for (i = 0; i < nusers; i++)
    if (ieq(users[i], n)) { u_unlock(); return; }
  if (nusers < 200) {
    cpy(users[nusers++], n, 24);
    qsort(users, nusers, 24, ucmp);
  }
  u_unlock();
}

static void user_del(const char *n)
{
  int i;
  u_lock();
  for (i = 0; i < nusers; i++)
    if (ieq(users[i], n)) {
      mv(users[i], users[i + 1], (nusers - i - 1) * 24);
      nusers--;
      break;
    }
  u_unlock();
}

static void mark_typing(const char *n, int on)
{
  int i, slot = -1;
  uint32 now = ms_now();
  u_lock();
  for (i = 0; i < 6; i++)
    if (typers[i].nick[0] && ieq(typers[i].nick, n))
      slot = i;
  if (!on) {
    if (slot >= 0) typers[slot].nick[0] = 0;
  } else {
    if (slot < 0)
      for (i = 0; i < 6; i++)
	if (!typers[i].nick[0] || (int)(typers[i].until - now) < 0) {
	  slot = i;
	  break;
	}
    if (slot >= 0) {
      cpy(typers[slot].nick, n, 24);
      typers[slot].until = now + 6000;
    }
  }
  u_unlock();
}

static void broadcast_color(void)
{
  if (cfg.hue >= 0)
    irc_send("NOTICE " IRC_CHAN " :\001DC99COLOR %d\001", cfg.hue);
}

static void irc_fail(const char *why)
{
  cpy(irc_err, why, sizeof(irc_err));
  irc_state = 4;
  irc_run = 0;
  ev_simple('S', "", "", irc_err);
}

static char cap_all[2000];
static int cap_more;

static void irc_handle(char *line)
{
  char *tags = 0, *prefix = 0, *cmd, *p = line, *params[16], *nick = "";
  char nickb[64];
  int np = 0, i, hist = 0;
  char *ttime = 0, *tbatch = 0, *ttyping = 0;

  if (*p == '@') { tags = p + 1; p = strchr(p, ' '); if (!p) return; *p++ = 0; }
  while (*p == ' ') p++;
  if (*p == ':') { prefix = p + 1; p = strchr(p, ' '); if (!p) return; *p++ = 0; }
  while (*p == ' ') p++;
  cmd = p;
  p = strchr(p, ' ');
  if (p) *p++ = 0;
  while (p && *p && np < 15) {
    while (*p == ' ') p++;
    if (!*p) break;
    if (*p == ':') { params[np++] = p + 1; break; }
    params[np++] = p;
    p = strchr(p, ' ');
    if (p) *p++ = 0;
  }
  if (prefix) {
    char *e = strchr(prefix, '!');
    int l = e ? (int)(e - prefix) : (int)strlen(prefix);
    if (l > 63) l = 63;
    memcpy(nickb, prefix, l);
    nickb[l] = 0;
    nick = nickb;
  }
  if (tags) {
    char *t = tags;
    while (t && *t) {
      char *n = strchr(t, ';');
      if (n) *n++ = 0;
      if (!strncmp(t, "time=", 5)) ttime = t + 5;
      else if (!strncmp(t, "batch=", 6)) tbatch = t + 6;
      else if (!strncmp(t, "+typing=", 8)) ttyping = t + 8;
      else if (!strncmp(t, "+draft/typing=", 14)) ttyping = t + 14;
      t = n;
    }
  }
  if (tbatch)
    for (i = 0; i < nhist_ref; i++)
      if (!strcmp(hist_ref[i], tbatch)) hist = 1;
  if (ttime && !hist && !tz_known) {	/* learn the console clock's zone */
    long utc;
    if (iso_time(ttime, &utc)) {
      clk_off = (long)time(0) - utc;
      tz_off = ((long)time(0) - utc + 450) / 900 * 900;
      if (tz_off > -16 * 3600 && tz_off < 16 * 3600)
	tz_known = 1;
      else
	tz_off = 0;
    }
  }
  /* (lines carry the server's UTC time ; the console clock gives the zone.
     Before that is known, times are UTC) */

  if (!strcmp(cmd, "PING")) { irc_send("PONG :%s", np ? params[0] : ""); return; }
  if (!strcmp(cmd, "CAP") && np >= 3) {
    const char *sub = params[1], *list = params[np - 1];
    if (!strcmp(sub, "LS")) {
      char req[200] = "";
      static const char *want[5] = { "batch", "message-tags", "chathistory",
				     "draft/chathistory", "server-time" };
      if (!cap_more) cap_all[0] = 0;
      if (strlen(cap_all) + strlen(list) + 2 < sizeof(cap_all)) {
	strcat(cap_all, " ");
	strcat(cap_all, list);
      }
      if (np >= 4 && !strcmp(params[2], "*")) { cap_more = 1; return; }
      cap_more = 0;
      list = cap_all;
      for (i = 0; i < 5; i++) {
	const char *f = list;
	size_t wl = strlen(want[i]);
	while ((f = strstr(f, want[i]))) {
	  if (f[-1] == ' ' && (f[wl] == 0 || f[wl] == ' ' || f[wl] == '=')) {
	    if (*req) strcat(req, " ");
	    strcat(req, want[i]);
	    break;
	  }
	  f += wl;
	}
      }
      if (*req) irc_send("CAP REQ :%s", req);
      else irc_send("CAP END");
    } else if (!strcmp(sub, "ACK")) {
      if (strstr(list, "batch")) cap_batch = 1;
      if (strstr(list, "message-tags")) cap_tags = 1;
      if (strstr(list, "chathistory")) cap_hist = 1;
      if (strstr(list, "server-time")) cap_time = 1;
      irc_send("CAP END");
    } else if (!strcmp(sub, "NAK"))
      irc_send("CAP END");
    return;
  }
  if (!strcmp(cmd, "BATCH") && np >= 1) {
    if (params[0][0] == '+' && np >= 2 && strstr(params[1], "chathistory")
	&& nhist_ref < 4)
      cpy(hist_ref[nhist_ref++], params[0] + 1, 16);
    else if (params[0][0] == '-')
      for (i = 0; i < nhist_ref; i++)
	if (!strcmp(hist_ref[i], params[0] + 1)) hist_ref[i][0] = 0;
    return;
  }
  if (!strcmp(cmd, "001")) {
    irc_state = 3;
    if (np) cpy(irc_me, params[0], sizeof(irc_me));
    if (cfg.hue >= 0) { u_lock(); set_hue(irc_me, cfg.hue); u_unlock(); }
    if (cfg.pass[0]) irc_send("PRIVMSG NickServ :REGISTER %s", cfg.pass);
    irc_send("JOIN " IRC_CHAN);
    if (cap_batch && cap_hist)
      irc_send("CHATHISTORY LATEST " IRC_CHAN " * 50");
    ev_simple('S', "", irc_me, "");
    return;
  }
  if (!strcmp(cmd, "464")) { irc_fail("Wrong password for that nickname."); return; }
  if (!strcmp(cmd, "433")) {
    if (irc_state < 3) irc_fail("That nickname is already in use. Pick another.");
    else sys_line(0, "That nickname is already in use.");
    return;
  }
  if (!strcmp(cmd, "432")) {
    irc_fail("That nickname is not allowed. Use letters, numbers, _ or -.");
    return;
  }
  if (!strcmp(cmd, "ERROR")) {
    irc_fail(np ? params[np - 1] : "The server closed the connection.");
    return;
  }
  if (!strcmp(cmd, "332") && np >= 3) {
    sys_line(IRC_CHAN, "Topic: %s", params[np - 1]);
    return;
  }
  if (!strcmp(cmd, "353") && np) {
    char *t = params[np - 1], *s;
    while ((s = strtok(t, " "))) {
      t = 0;
      while (*s == '@' || *s == '+' || *s == '%' || *s == '~' || *s == '&') s++;
      user_add(s);
    }
    return;
  }
  if (!strcmp(cmd, "366")) { users_changed(); return; }
  if (!strcmp(cmd, "JOIN")) {
    if (ieq(nick, IRC_BOT)) return;
    user_add(nick);
    users_changed();
    if (!hist) {
      if (!ieq(nick, irc_me) && cfg.sys)
	sys_line(IRC_CHAN, "%s joined " IRC_CHAN, nick);
      broadcast_color();
    }
    return;
  }
  if (!strcmp(cmd, "PART") || !strcmp(cmd, "QUIT")) {
    if (ieq(nick, IRC_BOT)) return;
    user_del(nick);
    mark_typing(nick, 0);
    users_changed();
    if (!hist && cfg.sys)
      sys_line(IRC_CHAN, "%s left " IRC_CHAN, nick);
    return;
  }
  if (!strcmp(cmd, "NICK") && np) {
    if (ieq(nick, IRC_BOT) || ieq(params[0], IRC_BOT)) return;
    u_lock();
    for (i = 0; i < nusers; i++)
      if (ieq(users[i], nick)) cpy(users[i], params[0], 24);
    {
      int h = -1, k;
      for (k = 0; k < nhues; k++)
	if (ieq(hues[k].nick, nick)) h = hues[k].hue;
      if (h >= 0) { set_hue(nick, -1); set_hue(params[0], h); }
    }
    u_unlock();
    if (ieq(nick, irc_me)) cpy(irc_me, params[0], sizeof(irc_me));
    users_changed();
    sys_line(0, "%s is now known as %s", nick, params[0]);
    return;
  }
  if (!strcmp(cmd, "TAGMSG")) {
    if (!ieq(nick, irc_me) && ttyping)
      mark_typing(nick, !strcmp(ttyping, "active") || !strcmp(ttyping, "paused"));
    return;
  }
  if (!strcmp(cmd, "PRIVMSG") && np >= 2) {
    const char *text = params[np - 1], *target = params[0];
    int dm = ieq(target, irc_me);
    const char *route = dm ? nick : IRC_CHAN;
    if (ieq(nick, "HistServ")) {
      if (!strncmp(text, IRC_BOT, strlen(IRC_BOT))) return;
      if (cfg.sys) irc_line('s', IRC_CHAN, "", text, ttime, hist);
      return;
    }
    if (ieq(nick, IRC_BOT)) return;
    if (is_service(nick)) { sys_line(IRC_CHAN, "[%s] %s", nick, text); return; }
    if (ieq(nick, irc_me) && !hist) return;
    if (is_ignored(nick)) return;
    if (target[0] != '#' && !dm) route = target;
    else if (target[0] == '#') route = target;
    mark_typing(nick, 0);
    if (!strncmp(text, "\001ACTION ", 8)) {
      char b[300];
      cpy(b, text + 8, sizeof(b));
      { char *e = strchr(b, 1); if (e) *e = 0; }
      irc_line('a', route, nick, b, ttime, hist);
    } else if (text[0] == 1)
      return;			/* other CTCP */
    else
      irc_line(ieq(nick, irc_me) ? 'o' : 'm', route, nick, text, ttime, hist);
    return;
  }
  if (!strcmp(cmd, "NOTICE") && np >= 2) {
    const char *text = params[np - 1];
    if (!strncmp(text, "\001DC99COLOR ", 11)) {
      const char *v = text + 11;
      int h = -1;
      if (strncmp(v, "reset", 5)) {
	h = atoi(v);
	if (!is_digit((unsigned char)*v) || h >= 360) return;
      }
      u_lock();
      set_hue(nick, h);
      h = nick_hue(nick);
      u_unlock();
      {
	chev_t *e;
	ev_lock();
	e = ev_new('c');
	cpy(e->nick, nick, sizeof(e->nick));
	e->hue = h;
	ev_unlock();
      }
      return;
    }
    if (ieq(nick, IRC_BOT)) return;
    if (*nick && is_service(nick))
      sys_line(IRC_CHAN, "[%s] %s", nick, text);
    else if (irc_state >= 3 && *nick && strchr(prefix ? prefix : "", '!'))
      sys_line(0, "-%s- %s", nick, text);
    return;
  }
  if (!strcmp(cmd, "KICK") && np >= 2) {
    user_del(params[1]);
    users_changed();
    sys_line(IRC_CHAN, "%s was removed by %s", params[1], nick);
    return;
  }
}

#define RBUF 4096
#define RXQ 16384

/* bytes received by the IRC thread, waiting for the main thread
   (chat_poll) to read the lines : all IRC work happens there, on the big
   main stack, not on the IRC thread's 8 KB one */
static char *rxq;
static int rx_len;

static void irc_pump(void)
{
  static char work[RXQ + 1];
  int n = 0, k = 0;
  char *a, *e;
  if (!rxq) return;
  ev_lock();
  if (rx_len) {
    /* whole lines only */
    for (k = rx_len; k > 0 && rxq[k - 1] != '\n'; k--) ;
    if (k > 0) {
      memcpy(work, rxq, k);
      mv(rxq, rxq + k, rx_len - k);
      rx_len -= k;
      n = k;
    } else if (rx_len >= RXQ - 1)
      rx_len = 0;		/* one endless line : forget it */
  }
  ev_unlock();
  if (!n) return;
  work[n] = 0;
  a = work;
  while ((e = strchr(a, '\n'))) {
    *e = 0;
    if (e > a && e[-1] == '\r') e[-1] = 0;
    if (*a) irc_handle(a);
    a = e + 1;
  }
}

static void irc_thread(void *arg)
{
  char *rbuf;
  int rlen = 0;
  uint32 t0;
  int s;

  (void)arg;
  CDBG("irc thread\n");
  rbuf = malloc(RBUF);
  ev_lock();
  if (!rxq) rxq = malloc(RXQ);
  rx_len = 0;
  ev_unlock();
  if (!rbuf || !rxq) {
    irc_fail("Not enough memory for the chat.");
    irc_done = 1;
    return;
  }
  snprintf(irc_stage, sizeof(irc_stage), "Looking up %s", cfg.host);
  s = tcp_open(cfg.host, cfg.port, irc_err, sizeof(irc_err));
  if (s < 0 || !irc_run) {
    if (s >= 0) close(s);
    if (irc_run) irc_fail(irc_err);
    free(rbuf);
    irc_done = 1;
    return;
  }
  irc_fd = s;
  cpy(irc_me, cfg.nick, sizeof(irc_me));
  cap_batch = cap_tags = cap_hist = cap_time = 0;
  nhist_ref = 0;
  cap_more = 0;
  snprintf(irc_stage, sizeof(irc_stage), "Logging in as %s", cfg.nick);
  irc_state = 2;
  ev_simple('S', "", "", "");
  irc_send("CAP LS 302");
  if (cfg.pass[0]) irc_send("PASS %s:%s", cfg.nick, cfg.pass);
  irc_send("NICK %s", cfg.nick);
  irc_send("USER %s 0 * :%s (DCPlaya for Dreamcast)", cfg.nick, cfg.nick);
  t0 = ms_now();

  while (irc_run) {
    /* what the player typed */
    for (;;) {
      static char line[440];	/* (IRC thread only) */
      ev_lock();
      if (!out_n) { ev_unlock(); break; }
      strcpy(line, outq[out_head]);
      out_head = (out_head + 1) % NOUT;
      out_n--;
      ev_unlock();
      if (send_all(s, line, strlen(line))) {
	if (irc_run) irc_fail("Lost the connection to the IRC server.");
	break;
      }
    }
    if (!irc_run) break;
    if (irc_state == 2 && ms_now() - t0 > 20000) {
      irc_fail("Connected, but the IRC server never finished the login.");
      break;
    }
    if (!wait_read(s, 100))
      continue;
    {
      int n = recv(s, rbuf, RBUF, 0);
      if (n <= 0) {
	if (irc_run)
	  irc_fail(irc_state == 3 ? "Disconnected from the IRC server."
		   : "The IRC server closed the connection before the login "
		   "finished. Check the server address.");
	break;
      }
      ev_lock();
      if (rxq && rx_len + n <= RXQ) {
	memcpy(rxq + rx_len, rbuf, n);
	rx_len += n;
      }
      ev_unlock();
    }
  }
  CDBG("irc thread leaving (state %d)\n", irc_state);
  if (irc_state == 3 || irc_state == 2) {	/* asked to leave */
    static const char q[] = "QUIT :Dreamcast out\r\n";
    send_all(s, q, sizeof(q) - 1);
    thd_sleep(200);
  }
  close(s);
  irc_fd = -1;
  if (irc_state != 4) irc_state = 0;
  ev_lock();
  out_n = 0;
  ev_unlock();
  u_lock();
  nusers = 0;
  u_unlock();
  free(rbuf);
  CDBG("irc thread done\n");
  irc_done = 1;
}

static void irc_stop(int wait)
{
  int i;
  irc_run = 0;
  for (i = 0; wait && i < 60 && !irc_done; i++)
    thd_sleep(50);
}

/* ------------------------------------------------------------------------
 * KosNet global chat, through http://dc99.net/online/app.php
 * ---------------------------------------------------------------------- */

static char kos_host[48] = "dc99.net";
static int kos_port = 80;
static char kos_path[64] = "/online/app.php";

typedef struct {
  char id[12], name[32], game[40], when[16], msg[304];
} kosmsg_t;
#define NKOS 40
static kosmsg_t *kos;
static int nkos, kos_irc = -1, kos_ver;
static char kos_err[160];

static volatile int kos_job, kos_run, kos_done = 1, kos_busy;
static char feed_q[64];		/* job 4 : a plain GET of the feed */
static char *feed_body;		/* its answer, until Lua takes it */
static char feed_got[64];
static char x_host[64], x_path[64], x_q[400];	/* job 6 */
static char feed_err[160];	/* why the last read failed */
static char kos_u[48], kos_p[64], kos_t[220], kos_m[260];

static void urlenc(const char *s, char *o, int max)
{
  static const char *hx = "0123456789ABCDEF";
  int n = 0;
  for (; *s && n < max - 4; s++) {
    unsigned char c = *s;
    if (is_alnum(c) || c == '-' || c == '_' || c == '.' || c == '~')
      o[n++] = c;
    else if (c == ' ')
      o[n++] = '+';
    else {
      o[n++] = '%';
      o[n++] = hx[c >> 4];
      o[n++] = hx[c & 15];
    }
  }
  o[n] = 0;
}

/* plain HTTP/1.0 ; returns the body (in http_buf, free it) or 0 */
#define HBUF 16000
static char *http_buf;

static const char *h_host, *h_path;	/* another server (job 6), else KosNet's */
static int h_port;

static char *http_req(const char *q, const char *post, char *err, int errn)
{
  const char *host = h_host ? h_host : kos_host;
  const char *path = h_path ? h_path : kos_path;
  int port = h_host ? h_port : kos_port;
  char *buf;
  static char req[1200];	/* (worker thread only) */
  int s, n = 0, k;
  uint32 t0;
  char *b;

  free(http_buf);
  http_buf = buf = malloc(HBUF);
  if (!buf) {
    snprintf(err, errn, "Not enough memory.");
    return 0;
  }
  s = tcp_open(host, port, err, errn);
  if (s < 0)
    return 0;
  if (post)
    k = snprintf(req, sizeof(req),
		 "POST %s?%s HTTP/1.1\r\nHost: %s\r\nUser-Agent: DCPlaya\r\n"
		 "Content-Type: application/x-www-form-urlencoded\r\n"
		 "Content-Length: %d\r\nConnection: close\r\n\r\n%s",
		 path, q, host, (int)strlen(post), post);
  else
    k = snprintf(req, sizeof(req),
		 "GET %s?%s HTTP/1.1\r\nHost: %s\r\nUser-Agent: DCPlaya\r\n"
		 "Connection: close\r\n\r\n", path, q, host);
  k = strlen(req);		/* (this libc's snprintf does not count) */
  CDBG("http send %d\n", k);
  if (send_all(s, req, k)) {
    CDBG("http send failed\n");
    close(s);
    snprintf(err, errn, "The server did not take the request.");
    return 0;
  }
  t0 = ms_now();
  while (n < HBUF - 1) {
    if (ms_now() - t0 > 20000) break;
    if (!wait_read(s, 500)) {
      if (!kos_run) break;
      continue;
    }
    k = recv(s, buf + n, HBUF - 1 - n, 0);
    CDBG("http recv %d\n", k);
    if (k <= 0) break;
    n += k;
  }
  close(s);
  buf[n] = 0;
  if (strncmp(buf, "HTTP/", 5)) {
    snprintf(err, errn, "No answer from the server.");
    return 0;
  }
  b = strstr(buf, "\r\n\r\n");
  if (!b) {
    snprintf(err, errn, "No answer from the server.");
    return 0;
  }
  {
    int code = 0;
    const char *c = strchr(buf, ' ');
    if (c) code = atoi(c + 1);
    if (code != 200) {
      snprintf(err, errn, code == 301 || code == 302
	       ? "The server sent a redirect (plain HTTP is needed)."
	       : "The server answered %d.", code);
      return 0;
    }
  }
  /* HTTP/1.1 (some hosts refuse 1.0) : the answer may come in chunks */
  {
    char *h = buf, *te = 0;
    *b = 0;
    for (; *h; h++)
      if ((h == buf || h[-1] == '\n')
	  && !ncase(h, "transfer-encoding:", 18)) {
	te = h + 18;
	break;
      }
    b += 4;
    if (te) {
      while (*te == ' ') te++;
      if (!ncase(te, "chunked", 7)) {
	char *r = b, *w = b;
	for (;;) {
	  long len = 0;
	  for (;; r++) {
	    int c = *r;
	    if (c >= '0' && c <= '9') c -= '0';
	    else if (c >= 'a' && c <= 'f') c -= 'a' - 10;
	    else if (c >= 'A' && c <= 'F') c -= 'A' - 10;
	    else break;
	    len = len * 16 + c;
	  }
	  r = strchr(r, '\n');
	  if (!r || len <= 0) break;
	  r++;
	  if (len > (long)strlen(r)) len = strlen(r);
	  while (len-- > 0)	/* (by hand : overlapping) */
	    *w++ = *r++;
	  if (*r == '\r') r++;
	  if (*r == '\n') r++;
	}
	*w = 0;
      }
    }
  }
  return b;
}

/* next tab separated field of a line ; 0 at the end */
static char *field(char **p)
{
  char *s = *p, *e;
  if (!s) return 0;
  e = strchr(s, '\t');
  if (e) { *e = 0; *p = e + 1; } else *p = 0;
  return s;
}

static void kos_refresh(void)
{
  static char err[160];
  char *b, *line;
  err[0] = 0;
  b = http_req("s=chat", 0, err, sizeof(err));
  kosmsg_t *tmp;
  int n = 0, irc = -1;

  if (!kos)
    kos = malloc(NKOS * sizeof(kosmsg_t));
  tmp = malloc(NKOS * sizeof(kosmsg_t));
  if (b && (!kos || !tmp)) {
    b = 0;
    cpy(err, "Not enough memory.", sizeof(err));
  }
  if (!b) {			/* keep what we had ; say why */
    free(tmp);
    free(http_buf);
    http_buf = 0;
    ev_lock();
    cpy(kos_err, err, sizeof(kos_err));
    kos_ver++;
    ev_new('K');
    ev_unlock();
    return;
  }
  err[0] = 0;
  while (b && *b) {
    char *e = strchr(b, '\n'), *p, *f;
    if (e) *e = 0;
    line = b;
    b = e ? e + 1 : 0;
    { int l = strlen(line); if (l && line[l - 1] == '\r') line[l - 1] = 0; }
    p = line;
    f = field(&p);
    if (!f) continue;
    if (!strcmp(f, "IRC")) {
      f = field(&p);
      irc = f ? atoi(f) : -1;
    } else if (!strcmp(f, "ERR")) {
      f = field(&p);
      cpy(err, f ? f : "KosNet error", sizeof(err));
    } else if (!strcmp(f, "C") && n < NKOS) {
      kosmsg_t *m = &tmp[n];
      memset(m, 0, sizeof(*m));
      cpy(m->id, field(&p), sizeof(m->id));
      cpy(m->name, field(&p), sizeof(m->name));
      cpy(m->game, field(&p), sizeof(m->game));
      cpy(m->when, field(&p), sizeof(m->when));
      {
	char *t = field(&p);
	utf8_in(t ? t : "", m->msg, sizeof(m->msg));
      }
      n++;
    }
  }
  free(http_buf);
  http_buf = 0;
  ev_lock();
  if (n || !err[0]) {
    memcpy(kos, tmp, n * sizeof(kosmsg_t));
    nkos = n;
  }
  free(tmp);
  kos_irc = irc;
  cpy(kos_err, err, sizeof(kos_err));
  kos_ver++;
  ev_new('K');
  ev_unlock();
}

static void kos_answer(char *b, const char *err, char *k, char *f1,
		       int f1n, char *f2, int f2n)
{
  *k = 0; *f1 = 0; *f2 = 0;
  if (!b) { cpy(f1, err, f1n); return; }
  while (b && *b) {
    char *e = strchr(b, '\n'), *p = b, *f;
    if (e) *e = 0;
    b = e ? e + 1 : 0;
    { int l = strlen(p); if (l && p[l - 1] == '\r') p[l - 1] = 0; }
    f = field(&p);
    if (!f) continue;
    if (!strcmp(f, "TOKEN") || !strcmp(f, "OK") || !strcmp(f, "ERR")) {
      *k = f[0];
      cpy(f1, field(&p), f1n);
      cpy(f2, field(&p), f2n);
      return;
    }
  }
  cpy(f1, "No answer from the server.", f1n);
}

/* ---- connection test : every step, in words, for the screen ---- */
static char diag[1400];
static volatile int diag_done = 1;

static void dg(const char *fmt, ...)
{
  static char b[200];
  va_list a;
  int n = strlen(diag);
  va_start(a, fmt);
  vsnprintf(b, sizeof(b), fmt, a);
  va_end(a);
  b[sizeof(b) - 1] = 0;
  if (n + (int)strlen(b) + 2 < (int)sizeof(diag)) {
    strcat(diag, b);
    strcat(diag, "\n");
  }
}

static void dg_ip(char *o, uint32 a)
{
  unsigned char *ip = (unsigned char *)&a;
  sprintf(o, "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
}

/* look a name up with each DNS server in turn, saying what happened */
static int dg_lookup(const char *name, uint32 *out)
{
  static char ipb[20];
  uint32 srv[3];
  int i, n = 0;
  if (!dns_parse_ip(name, out)) return 0;
  if (dnssrv.sin_addr.s_addr) srv[n++] = dnssrv.sin_addr.s_addr;
  dns_parse_ip("1.1.1.1", &srv[n++]);
  dns_parse_ip("8.8.8.8", &srv[n++]);
  if (!dnsm) dnsm = mutex_create();
  for (i = 0; i < n; i++) {
    int ok;
    dg_ip(ipb, srv[i]);
    mutex_lock(dnsm);
    ok = !dns_ask(srv[i], name, out, 3000);
    mutex_unlock(dnsm);
    if (ok) {
      static char ipa[20];
      dg_ip(ipa, *out);
      dg("  %s : found %s (DNS %s)", name, ipa, ipb);
      return 0;
    }
    dg("  %s : no answer from DNS %s", name, ipb);
  }
  return -1;
}

static int dg_connect(uint32 a, int port)
{
  struct sockaddr_in sa;
  int s;
  uint32 t0 = ms_now();
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons(port);
  sa.sin_addr.s_addr = a;
  s = socket(PF_INET, SOCK_STREAM, 0);
  if (s < 0) { dg("  no free socket"); return -1; }
  if (connect(s, (struct sockaddr *)&sa, sizeof(sa))) {
    close(s);
    dg("  port %d : could not connect (%d ms)", port, (int)(ms_now() - t0));
    return -1;
  }
  dg("  port %d : connected (%d ms)", port, (int)(ms_now() - t0));
  return s;
}

static void diag_run(void)
{
  static char ipb[20], err[160];
  uint32 a;
  int s;
  char *b;
  diag[0] = 0;
  dg_ip(ipb, dnssrv.sin_addr.s_addr);
  dg("DNS server from the network settings : %s",
     dnssrv.sin_addr.s_addr ? ipb : "none");
  dg("1. The server (%s)", kos_host);
  if (!dg_lookup(kos_host, &a) && (s = dg_connect(a, kos_port)) >= 0) {
    close(s);
    err[0] = 0;
    b = http_req("s=online", 0, err, sizeof(err));
    if (b) {
      char *st = strstr(b, "STAT\t");
      int n = strlen(b);
      if (st) {
	char *e = strchr(st, '\n');
	if (e) *e = 0;
	{ char *t; for (t = st; *t; t++) if (*t == '\t') *t = ' '; }
      }
      dg("  feed : %d bytes, %s", n, st ? st : "no STAT line");
    } else
      dg("  feed : %s", err);
    free(http_buf);
    http_buf = 0;
  }
  dg("2. IRC (%s)", cfg.host);
  if (!dg_lookup(cfg.host, &a) && (s = dg_connect(a, cfg.port)) >= 0)
    close(s);
  dg("Done.");
}

static void kos_thread(void *arg)
{
  (void)arg;
  while (kos_run) {
    int j = kos_job;
    if (!j) {
      thd_sleep(100);
      continue;
    }
    kos_busy = 1;
    kos_job = 0;
    if (j == 1)
      kos_refresh();
    else if (j == 5) {
      diag_run();
      diag_done = 1;
      ev_simple('D', "", "", "test");
    } else if (j == 4 || j == 6) {	/* dashboard feed / another server */
      static char err[160];
      char *b, *c = 0;
      err[0] = 0;
      if (j == 6) {
	h_host = x_host; h_path = x_path; h_port = 80;
	cpy(feed_q, "http", sizeof(feed_q));
	b = http_req(x_q, 0, err, sizeof(err));
	h_host = h_path = 0;
      } else
	b = http_req(feed_q, 0, err, sizeof(err));
      cpy(feed_err, err, sizeof(feed_err));
      if (b && (c = malloc(strlen(b) + 1)))
	strcpy(c, b);
      free(http_buf);
      http_buf = 0;
      ev_lock();
      free(feed_body);
      feed_body = c;
      cpy(feed_got, feed_q, sizeof(feed_got));
      {
	chev_t *e = ev_new('D');
	cpy(e->text, feed_q, sizeof(e->text));
	if (!c) cpy(e->nick, "fail", sizeof(e->nick));
      }
      ev_unlock();
    } else {
      static char body[1400], a[400], c[700], err[160], f1[220], f2[40];
      char k, *r;
      err[0] = 0;
      chev_t *e;
      if (j == 2) {
	urlenc(kos_u, a, sizeof(a));
	urlenc(kos_p, c, sizeof(c));
	memset(kos_p, 0, sizeof(kos_p));
	snprintf(body, sizeof(body), "u=%s&p=%s", a, c);
	r = http_req("s=klogin", body, err, sizeof(err));
	memset(body, 0, sizeof(body));
	memset(c, 0, sizeof(c));
      } else {
	urlenc(kos_t, a, sizeof(a));
	urlenc(kos_m, c, sizeof(c));
	snprintf(body, sizeof(body), "t=%s&m=%s", a, c);
	r = http_req("s=ksay", body, err, sizeof(err));
      }
      kos_answer(r, err, &k, f1, sizeof(f1), f2, sizeof(f2));
      free(http_buf);
      http_buf = 0;
      ev_lock();
      if (k == 'T' && f1[0]) {
	e = ev_new('T');	/* signed in : token, name */
	cpy(e->text, f1, sizeof(e->text));
	cpy(e->nick, f2[0] ? f2 : kos_u, sizeof(e->nick));
      } else if (k == 'O') {
	e = ev_new('O');	/* sent */
      } else {
	e = ev_new('E');
	cpy(e->text, f1[0] ? f1 : "KosNet said no.", sizeof(e->text));
	e->mention = j;		/* 2 : sign-in, 3 : post */
	/* a session that ended : the Lua side forgets the token */
	if (j == 3 && (strstr(f1, "sign in") || strstr(f1, "session")))
	  e->hist = 1;
      }
      ev_unlock();
      if (k == 'O')
	kos_refresh();
    }
    kos_busy = 0;
  }
  kos_done = 1;
}

static int kos_start(void)
{
  kthread_t *t;
  if (kos_run)
    return 0;
  if (!kos_done)
    return -1;
  kos_run = 1;
  kos_done = 0;
  t = thd_create(kos_thread, 0);
  if (!t) {
    kos_run = 0;
    kos_done = 1;
    return -1;
  }
  thd_set_label(t, "kosnet");
  return 0;
}

/* ------------------------------------------------------------------------
 * The DC99NET file the DC99 app keeps on the memory card : same nickname,
 * password, colour and KosNet sign-in in both apps. Read only.
 * ---------------------------------------------------------------------- */

static int rd32(const uint8 *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24); }

static int read_dc99net(uint8 *d)	/* d[600] ; 0 if found */
{
  static const char *ports = "abcd";
  int i, u;
  uint8 *f = malloc(16384);
  if (!f)
    return -1;
  for (i = 0; i < 4; i++)
    for (u = 1; u <= 2; u++) {
      char fn[32];
      file_t h;
      int n, off, ic, ec;
      sprintf(fn, "/vmu/%c%d/DC99NET", ports[i], u);
      h = fs_open(fn, O_RDONLY);
      if (h == FILEHND_INVALID || h == 0)
	continue;
      n = fs_read(h, f, 16384);
      fs_close(h);
      if (n < 0x80 + 600)
	continue;
      ic = f[0x40] | (f[0x41] << 8);
      ec = f[0x44] | (f[0x45] << 8);
      off = 0x80 + ic * 512 + (ec == 1 ? 8064 : ec == 2 ? 4544 : ec == 3 ? 2048 : 0);
      if (off + 600 > n || memcmp(f + off, "DC99", 4)) {
	for (off = 0x80; off + 600 <= n; off++)
	  if (!memcmp(f + off, "DC99", 4)) break;
	if (off + 600 > n)
	  continue;
      }
      memcpy(d, f + off, 600);
      free(f);
      return 0;
    }
  free(f);
  return -1;
}

/* ------------------------------------------------------------------------
 * Lua
 * ---------------------------------------------------------------------- */

static void set_s(lua_State *L, const char *k, const char *v)
{
  lua_pushstring(L, k);
  lua_pushstring(L, v);
  lua_settable(L, -3);
}

static void set_n(lua_State *L, const char *k, double v)
{
  lua_pushstring(L, k);
  lua_pushnumber(L, v);
  lua_settable(L, -3);
}

static const char *get_s(lua_State *L, int t, const char *k)
{
  const char *s;
  lua_pushstring(L, k);
  lua_gettable(L, t);
  s = lua_isstring(L, -1) ? lua_tostring(L, -1) : 0;
  lua_settop(L, t);		/* (the string stays alive in the table) */
  return s;
}

static int get_n(lua_State *L, int t, const char *k, int def)
{
  int v = def;
  lua_pushstring(L, k);
  lua_gettable(L, t);
  if (lua_isnumber(L, -1)) v = (int)lua_tonumber(L, -1);
  lua_settop(L, t);
  return v;
}

static void cfg_from(lua_State *L, int t)
{
  const char *s;
  if ((s = get_s(L, t, "host")) && *s) cpy(cfg.host, s, sizeof(cfg.host));
  cfg.port = get_n(L, t, "port", cfg.port);
  if ((s = get_s(L, t, "nick"))) cpy(cfg.nick, s, sizeof(cfg.nick));
  if ((s = get_s(L, t, "pass"))) cpy(cfg.pass, s, sizeof(cfg.pass));
  cfg.hue = get_n(L, t, "hue", cfg.hue);
  cfg.ts = get_n(L, t, "ts", cfg.ts);
  cfg.sys = get_n(L, t, "sys", cfg.sys);
  if ((s = get_s(L, t, "ignore"))) {	/* "a,b,c" */
    int i = 0;
    memset(cfg.ignore, 0, sizeof(cfg.ignore));
    while (*s && i < 8) {
      int n = 0;
      while (*s == ',' || *s == ' ') s++;
      while (*s && *s != ',' && n < 23) cfg.ignore[i][n++] = *s++;
      while (*s && *s != ',') s++;
      if (n) i++;
    }
  }
}

static void cfg_push(lua_State *L)
{
  char ig[200] = "";
  int i;
  lua_newtable(L);
  set_s(L, "host", cfg.host);
  set_n(L, "port", cfg.port);
  set_s(L, "nick", cfg.nick);
  set_s(L, "pass", cfg.pass);
  set_n(L, "hue", cfg.hue);
  set_n(L, "ts", cfg.ts);
  set_n(L, "sys", cfg.sys);
  for (i = 0; i < 8; i++)
    if (cfg.ignore[i][0]) {
      if (*ig) strcat(ig, ",");
      strcat(ig, cfg.ignore[i]);
    }
  set_s(L, "ignore", ig);
}

/* chat_cfg([t]) : set what is in t ; returns the settings */
int lua_chat_cfg(lua_State *L)
{
  if (lua_type(L, 1) == LUA_TTABLE)
    cfg_from(L, 1);
  lua_settop(L, 0);
  cfg_push(L);
  return 1;
}

/* chat_irc_start([t]) : 1 if a connection was started */
int lua_chat_irc_start(lua_State *L)
{
  kthread_t *t;
  CDBG("irc_start: state %d done %d\n", irc_state, irc_done);
  if (lua_type(L, 1) == LUA_TTABLE)
    cfg_from(L, 1);
  CDBG("irc_start: cfg %s %d %s\n", cfg.host, cfg.port, cfg.nick);
  lua_settop(L, 0);
  if (irc_state == 1 || irc_state == 2 || irc_state == 3 || !irc_done)
    return 0;
  if (!cfg.nick[0]) {
    cpy(irc_err, "Type a nickname first.", sizeof(irc_err));
    irc_state = 4;
    return 0;
  }
  irc_err[0] = 0;
  irc_state = 1;
  irc_run = 1;
  irc_done = 0;
  t = thd_create(irc_thread, 0);
  if (!t) {
    irc_run = 0;
    irc_done = 1;
    irc_state = 4;
    cpy(irc_err, "Could not start the chat.", sizeof(irc_err));
    return 0;
  }
  thd_set_label(t, "irc");
  CDBG("irc_start: thread %p\n", t);
  lua_pushnumber(L, 1);
  return 1;
}

int lua_chat_irc_stop(lua_State *L)
{
  irc_stop(1);
  irc_state = 0;
  irc_err[0] = 0;
  return 0;
}

/* chat_irc_state() : state, message, my nick, number of people */
int lua_chat_irc_state(lua_State *L)
{
  lua_settop(L, 0);
  lua_pushnumber(L, irc_state);
  lua_pushstring(L, irc_state == 4 ? irc_err : irc_stage);
  lua_pushstring(L, irc_me);
  lua_pushnumber(L, nusers);
  return 4;
}

/* chat_irc_users() : { n, [i] = { nick, hue } } */
int lua_chat_irc_users(lua_State *L)
{
  int i;
  lua_settop(L, 0);
  lua_newtable(L);
  u_lock();
  for (i = 0; i < nusers; i++) {
    lua_newtable(L);
    set_s(L, "nick", users[i]);
    set_n(L, "hue", nick_hue(users[i]));
    lua_rawseti(L, 1, i + 1);
  }
  set_n(L, "n", nusers);
  u_unlock();
  return 1;
}

/* chat_irc_typers() : "Ann, Bob" or nil */
int lua_chat_irc_typers(lua_State *L)
{
  char b[160] = "";
  int i, n = 0;
  uint32 now = ms_now();
  lua_settop(L, 0);
  u_lock();
  for (i = 0; i < 6; i++)
    if (typers[i].nick[0] && (int)(typers[i].until - now) > 0) {
      if (n) strcat(b, ", ");
      strncat(b, typers[i].nick, 23);
      n++;
    }
  u_unlock();
  if (!n) return 0;
  lua_pushstring(L, b);
  lua_pushnumber(L, n);
  return 2;
}

/* chat_irc_hue(nick) */
int lua_chat_irc_hue(lua_State *L)
{
  const char *n = lua_tostring(L, 1);
  int h;
  if (!n) return 0;
  u_lock();
  h = ieq(n, irc_me) && cfg.hue >= 0 ? cfg.hue : nick_hue(n);
  u_unlock();
  lua_settop(L, 0);
  lua_pushnumber(L, h);
  return 1;
}

/* chat_irc_typing(conv) : tell the others we are typing (every 3 s) */
int lua_chat_irc_typing(lua_State *L)
{
  const char *c = lua_tostring(L, 1);
  uint32 now = ms_now();
  if (c && cap_tags && irc_state == 3 && (now - typing_sent > 3000 || !typing_sent)) {
    irc_send("@+typing=active TAGMSG %s", c);
    typing_sent = now;
  }
  return 0;
}

static const struct { const char *n; int h; } named_hue[10] = {
  { "red", 0 }, { "orange", 28 }, { "yellow", 50 }, { "green", 100 },
  { "teal", 160 }, { "cyan", 190 }, { "blue", 215 }, { "purple", 265 },
  { "pink", 320 }, { "rose", 345 }
};

/* chat_irc_say(conv, text) : a line typed by the player, commands too.
   Returns 1 when the settings changed (to be saved). */
int lua_chat_irc_say(lua_State *L)
{
  const char *target = lua_tostring(L, 1);
  const char *in = lua_tostring(L, 2);
  char text[300];
  int i, changed = 0;

  if (!target || !in) return 0;
  while (*in == ' ') in++;
  cpy(text, in, sizeof(text));
  { int n = strlen(text); while (n && text[n - 1] == ' ') text[--n] = 0; }
  lua_settop(L, 2);		/* (keeps target alive) */
  if (!text[0]) return 0;
  if (cap_tags && irc_state == 3) {
    irc_send("@+typing=done TAGMSG %s", target);
    typing_sent = 0;
  }
  if (ieq(text, "/help") || ieq(text, "/?")) {
    sys_line(target, "/me <action>   /msg <nick> <text>   /nick <name>");
    sys_line(target, "/color red orange yellow green teal cyan blue "
	     "purple pink rose random reset");
    sys_line(target, "/ignore <nick>   /unignore <nick>   /time 12|24|off"
	     "   /joins on|off");
    sys_line(target, "Enter sends. Tab or Y: next conversation. "
	     "F5 or X: KosNet.");
    return 0;
  }
  if (irc_state != 3) {
    sys_line(target, "Not connected to IRC.");
    return 0;
  }
  if (!ncase(text, "/me ", 4)) {
    irc_line('a', target, irc_me, text + 4, 0, 0);
    irc_send("PRIVMSG %s :\001ACTION %s\001", target, text + 4);
    return 0;
  }
  if (!ncase(text, "/msg ", 5)) {
    char *who = text + 5, *msg;
    while (*who == ' ') who++;
    msg = strchr(who, ' ');
    if (!msg || !msg[1]) {
      sys_line(target, "Usage: /msg <nick> <message>");
      return 0;
    }
    *msg++ = 0;
    irc_send("PRIVMSG %s :%s", who, msg);
    if (!is_service(who))
      irc_line('o', who, irc_me, msg, 0, 0);
    return 0;
  }
  if (!ncase(text, "/color", 6) || !ncase(text, "/colour", 7)) {
    char *a = text + (text[5] == 'u' ? 7 : 6);
    int hue = -2;
    while (*a == ' ') a++;
    for (i = 0; a[i]; i++) a[i] = lower((unsigned char)a[i]);
    if (!*a) {
      sys_line(target, "Usage: /color <name> - red, orange, yellow, green, "
	       "teal, cyan, blue, purple, pink, rose, random, or reset.");
      return 0;
    }
    if (!strcmp(a, "reset")) {
      cfg.hue = -1;
      u_lock(); set_hue(irc_me, -1); i = nick_hue(irc_me); u_unlock();
      irc_send("NOTICE " IRC_CHAN " :\001DC99COLOR reset\001");
      sys_line(target, "Color reset to default.");
    } else {
      if (!strcmp(a, "random")) hue = (int)(ms_now() * 7919u % 360);
      for (i = 0; i < 10; i++)
	if (!strcmp(a, named_hue[i].n)) hue = named_hue[i].h;
      if (hue == -2 && is_digit((unsigned char)a[0]) && atoi(a) < 360)
	hue = atoi(a);
      if (hue < 0) {
	sys_line(target, "Unknown color \"%s\".", a);
	return 0;
      }
      cfg.hue = hue;
      u_lock(); set_hue(irc_me, hue); u_unlock();
      broadcast_color();
      sys_line(target, "Your name color is updated. "
	       "Letting everyone else know...");
      i = hue;
    }
    {
      chev_t *e;
      ev_lock();
      e = ev_new('c');
      cpy(e->nick, irc_me, sizeof(e->nick));
      e->hue = i;
      ev_unlock();
    }
    changed = 1;
  } else if (!ncase(text, "/ignore ", 8) || !ncase(text, "/unignore ", 10)) {
    int un = lower((unsigned char)text[1]) == 'u';
    char *who = text + (un ? 10 : 8);
    while (*who == ' ') who++;
    for (i = 0; i < 8; i++)
      if (cfg.ignore[i][0] && ieq(cfg.ignore[i], who)) {
	if (un) cfg.ignore[i][0] = 0;
	break;
      }
    if (!un && i == 8) {
      for (i = 0; i < 8 && cfg.ignore[i][0]; i++) ;
      if (i < 8) cpy(cfg.ignore[i], who, 24);
    }
    sys_line(target, un ? "No longer ignoring %s." : "Ignoring %s.", who);
    changed = 1;
  } else if (!ncase(text, "/time ", 6)) {
    cfg.ts = !strcmp(text + 6, "24") ? 1 : (!strcmp(text + 6, "off") ? 2 : 0);
    sys_line(target, "Timestamps updated.");
    changed = 1;
  } else if (!ncase(text, "/joins ", 7)) {
    cfg.sys = !icase(text + 7, "on");
    sys_line(target, "Join/leave messages %s.", cfg.sys ? "shown" : "hidden");
    changed = 1;
  } else if (!ncase(text, "/nick ", 6)) {
    irc_send("NICK %s", text + 6);
  } else if (!ncase(text, "/join ", 6)) {
    irc_send("JOIN %s", text + 6);
  } else if (text[0] == '/') {
    irc_send("%s", text + 1);
  } else {
    irc_line('o', target, irc_me, text, 0, 0);
    irc_send("PRIVMSG %s :%s", target, text);
  }
  lua_settop(L, 0);
  if (changed) {
    lua_pushnumber(L, 1);
    return 1;
  }
  return 0;
}

/* chat_poll() : nil, or { n, [i] = event }
   event.k : "msg" "act" "mine" "sys" (a line : conv nick text ts hue
             mention hist), "users", "state", "color" (nick hue),
             "kos" (new KosNet list), "kostoken" (text = token, nick =
             name), "kossent", "koserr" (text, what = 2 sign-in / 3 post,
             ended = 1 when the session is over) */
int lua_chat_poll(lua_State *L)
{
  int i = 0;
  irc_pump();			/* IRC lines are handled here */
  lua_settop(L, 0);
  if (!ev_n) return 0;
  lua_newtable(L);
  ev_lock();
  while (ev_n && i < 64) {
    chev_t *e = &evq[ev_head];
    const char *k = "?";
    ev_head = (ev_head + 1) % NEV;
    ev_n--;
    switch (e->k) {
    case 'm': k = "msg"; break;
    case 'a': k = "act"; break;
    case 'o': k = "mine"; break;
    case 's': k = "sys"; break;
    case 'u': k = "users"; break;
    case 'S': k = "state"; break;
    case 'c': k = "color"; break;
    case 'K': k = "kos"; break;
    case 'T': k = "kostoken"; break;
    case 'O': k = "kossent"; break;
    case 'E': k = "koserr"; break;
    case 'D': k = "feed"; break;
    }
    lua_newtable(L);
    set_s(L, "k", k);
    if (e->conv[0]) set_s(L, "conv", e->conv);
    if (e->nick[0]) set_s(L, "nick", e->nick);
    if (e->text[0]) set_s(L, "text", e->text);
    if (e->ts[0]) set_s(L, "ts", e->ts);
    if (e->hue >= 0) set_n(L, "hue", e->hue);
    if (e->k == 'E') {
      set_n(L, "what", e->mention);
      if (e->hist) set_n(L, "ended", 1);
    } else {
      if (e->mention) set_n(L, "mention", 1);
      if (e->hist) set_n(L, "hist", 1);
    }
    lua_rawseti(L, 1, ++i);
  }
  ev_unlock();
  set_n(L, "n", i);
  return 1;
}

/* chat_kos_server(host, port, path) : for tests */
int lua_chat_kos_server(lua_State *L)
{
  if (lua_isstring(L, 1)) cpy(kos_host, lua_tostring(L, 1), sizeof(kos_host));
  if (lua_isnumber(L, 2)) kos_port = (int)lua_tonumber(L, 2);
  if (lua_isstring(L, 3)) cpy(kos_path, lua_tostring(L, 3), sizeof(kos_path));
  return 0;
}

/* chat_kos_refresh() : 1 if asked (the list arrives as a "kos" event) */
int lua_chat_kos_refresh(lua_State *L)
{
  lua_settop(L, 0);
  if (kos_start() < 0 || kos_job || kos_busy) return 0;
  kos_job = 1;
  lua_pushnumber(L, 1);
  return 1;
}

/* chat_kos_login(user, password) */
int lua_chat_kos_login(lua_State *L)
{
  const char *u = lua_tostring(L, 1), *p = lua_tostring(L, 2);
  if (!u || !p || kos_start() < 0 || kos_busy) return 0;
  cpy(kos_u, u, sizeof(kos_u));
  cpy(kos_p, p, sizeof(kos_p));
  kos_job = 2;
  lua_settop(L, 0);
  lua_pushnumber(L, 1);
  return 1;
}

/* chat_kos_say(token, message) */
int lua_chat_kos_say(lua_State *L)
{
  const char *t = lua_tostring(L, 1), *m = lua_tostring(L, 2);
  if (!t || !m || kos_start() < 0 || kos_busy) return 0;
  cpy(kos_t, t, sizeof(kos_t));
  cpy(kos_m, m, 201);		/* KosNet takes 200 characters */
  kos_job = 3;
  lua_settop(L, 0);
  lua_pushnumber(L, 1);
  return 1;
}

/* chat_kos_list() : { n, irc, err, busy, ver, [i] = { id name game time msg } } */
int lua_chat_kos_list(lua_State *L)
{
  int i;
  lua_settop(L, 0);
  lua_newtable(L);
  ev_lock();
  for (i = 0; kos && i < nkos; i++) {
    lua_newtable(L);
    set_s(L, "id", kos[i].id);
    set_s(L, "name", kos[i].name);
    set_s(L, "game", kos[i].game);
    set_s(L, "time", kos[i].when);
    set_s(L, "msg", kos[i].msg);
    lua_rawseti(L, 1, i + 1);
  }
  set_n(L, "n", nkos);
  set_n(L, "irc", kos_irc);
  set_n(L, "ver", kos_ver);
  if (kos_err[0]) set_s(L, "err", kos_err);
  ev_unlock();
  set_n(L, "busy", (kos_job || kos_busy) ? 1 : 0);
  return 1;
}

/* chat_feed(query) : read the server's feed (answer : a "feed" event,
   then chat_feed_body()). nil if the worker is busy : try again later. */
int lua_chat_feed(lua_State *L)
{
  const char *q = lua_tostring(L, 1);
  if (!q || kos_start() < 0 || kos_job || kos_busy) return 0;
  cpy(feed_q, q, sizeof(feed_q));
  kos_job = 4;
  lua_settop(L, 0);
  lua_pushnumber(L, 1);
  return 1;
}

/* chat_http(host, path, query) : plain GET from another server (weather) ;
   answer : a "feed" event with text "http", then chat_feed_body() */
int lua_chat_http(lua_State *L)
{
  const char *h = lua_tostring(L, 1), *p = lua_tostring(L, 2),
    *q = lua_tostring(L, 3);
  if (!h || !p || kos_start() < 0 || kos_job || kos_busy) return 0;
  cpy(x_host, h, sizeof(x_host));
  cpy(x_path, p, sizeof(x_path));
  cpy(x_q, q ? q : "", sizeof(x_q));
  kos_job = 6;
  lua_settop(L, 0);
  lua_pushnumber(L, 1);
  return 1;
}

/* chat_feed_body() : the last answer (once), and its query */
int lua_chat_feed_body(lua_State *L)
{
  lua_settop(L, 0);
  ev_lock();
  if (!feed_body) {
    lua_pushnil(L);
    lua_pushstring(L, feed_got);
    lua_pushstring(L, feed_err[0] ? feed_err : "No answer from the server.");
    ev_unlock();
    return 3;
  }
  lua_pushstring(L, feed_body);
  lua_pushstring(L, feed_got);
  free(feed_body);
  feed_body = 0;
  ev_unlock();
  return 2;
}

/* chat_test() : run the connection test (a "feed" event with text
   "test" when it is done, then chat_test_log()) */
int lua_chat_test(lua_State *L)
{
  lua_settop(L, 0);
  if (kos_start() < 0 || kos_job || kos_busy) return 0;
  diag_done = 0;
  diag[0] = 0;
  kos_job = 5;
  lua_pushnumber(L, 1);
  return 1;
}

/* chat_test_log() : the test's lines so far, and 1 when it is done */
int lua_chat_test_log(lua_State *L)
{
  lua_settop(L, 0);
  lua_pushstring(L, diag);
  lua_pushnumber(L, diag_done);
  return 2;
}

/* chat_time() : the console clock, seconds since 1970 */
int lua_chat_time(lua_State *L)
{
  lua_settop(L, 0);
  lua_pushnumber(L, (double)time(0));
  return 1;
}

/* chat_dc99net() : the DC99 app's settings from the memory card, or nil */
int lua_chat_dc99net(lua_State *L)
{
  static uint8 d[600];
  char b[220];
  int i;
  char ig[200] = "";
  lua_settop(L, 0);
  if (read_dc99net(d))
    return 0;
  lua_newtable(L);
  cpy(b, (char *)d + 56, 24);  set_s(L, "nick", b);
  cpy(b, (char *)d + 80, 40);  set_s(L, "pass", b);
  set_n(L, "hue", rd32(d + 120));
  set_n(L, "sound", rd32(d + 124));
  set_n(L, "ts", rd32(d + 128));
  set_n(L, "sys", rd32(d + 132));
  for (i = 0; i < 8; i++) {
    cpy(b, (char *)d + 136 + i * 24, 24);
    if (b[0]) {
      if (*ig) strcat(ig, ",");
      strcat(ig, b);
    }
  }
  set_s(L, "ignore", ig);
  cpy(b, (char *)d + 328, 200); set_s(L, "token", b);
  cpy(b, (char *)d + 528, 32);  set_s(L, "kname", b);
  cpy(b, (char *)d + 560, 40);  set_s(L, "host", b);
  return 1;
}

/* chat_dbg(text) : a line on the serial port (tests) */
int lua_chat_dbg(lua_State *L)
{
  const char *t = lua_tostring(L, 1);
  dbg_on = 1;
  if (t) CDBG("%s\n", t);
  return 0;
}

/* called when the net plugin goes away : no thread may be left running */
void chat_shutdown(void)
{
  int i;
  irc_stop(1);
  kos_run = 0;
  for (i = 0; i < 100 && !kos_done; i++)
    thd_sleep(50);
}
