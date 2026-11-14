/**
 * @ingroup  exe_plugin
 * @file     net_driver.c
 * @author   Vincent Penne <ziggy@sashipa.com> 
 * @date     2004/03/13
 * @brief    network extension plugin
 * 
 * $Id: net_driver.c,v 1.4 2007-03-17 14:40:29 vincentp Exp $
 */

#include <stdlib.h>
#include <string.h>

#include <kos.h>

#include "dcplaya/config.h"
#include "luashell.h"
#include "lef.h"
#include "driver_list.h"
#include "net_driver.h"

#include "net.h"

#include "lwip/lwip.h"

/** Lua side init flags. */
static int init;
static int netinit;
static int lwipinit;

static int driver_shutdown(any_driver_t * d);


static net_input_func saved_rx_callback;
net_input_func lwip_cb;
void rx_callback(netif_t * netif, uint8 *pkt, int pktsize);

netif_t * netif;


/* from console.c */
extern int (*old_printk_func)(const uint8 *data, int len, int xlat);


static int (* net_driver_init)();
static int (* net_driver_shutdown)();
static lef_prog_t * net_driver_lef;
static netif_t * * net_driver_if;


static int net_driver_close()
{
/*   if (net_driver_if) */
/*     net_unreg_device(net_driver_if); */

  if (net_driver_if && net_driver_init && net_driver_shutdown)
    net_driver_shutdown();

  if (net_driver_lef)
    lef_free(net_driver_lef);

  net_driver_init = 0;
  net_driver_shutdown = 0;
  net_driver_if = 0;
}

static int net_driver_open(const char * name)
{
  net_driver_lef = lef_load(name);
  if (!net_driver_lef)
    goto error;

  net_driver_init = lef_find_symbol(net_driver_lef, "_driver_init");
  net_driver_shutdown = lef_find_symbol(net_driver_lef, "_driver_shutdown");
  net_driver_if = lef_find_symbol(net_driver_lef, "_netif");

  if (!net_driver_if || !net_driver_init || !net_driver_shutdown) {
    printf("net_driver_open: no netif symbol found in '%s'\n", name);
    goto error;
  }

  if (net_driver_init && net_driver_init()) {
    printf("net_driver_open: driver_init failed in '%s'\n", name);
    goto error;
  }

  /* Try to detect/init us */
  if ((*net_driver_if)->if_detect(*net_driver_if) < 0) {
    printf("net_driver_open: can't detect adapter '%s'\n", name);
    goto error;
  }

  return 0;
 error:
  net_driver_close();
  
  return -1;
}


struct sockaddr_in dnssrv;

/* ------------------------------------------------------------------------
 * Dreamcast Now presence.
 *
 * A DreamPi works out which program a Dreamcast is running from the name of
 * the most recent DNS lookup it sees. While the network is up we therefore
 * look up DCNOW_NAME: a few times straight after the DNS server is set, then
 * about once a minute, and again right after every real host lookup (which
 * would otherwise hide it). Only the query has to reach the DNS server, so
 * the answer is never waited for.
 * ---------------------------------------------------------------------- */
#define DCNOW_NAME   "dcplaya.dnslookup"
#define DCNOW_PERIOD 60		/* seconds between lookups */

static kthread_t * dcnow_thd;
static volatile int dcnow_run;
static volatile int dcnow_done;

static void dcnow_ping(void)
{
  static unsigned int id = 0xdc00;
  static const char name[] = DCNOW_NAME;
  struct sockaddr_in to;
  uint8 q[12 + sizeof(name) + 1 + 4];
  int i, o, ls, sock;

  if (!lwipinit || !dnssrv.sin_port)
    return;

  /* header : id, flags (recursion desired), 1 question */
  memset(q, 0, sizeof(q));
  ++id;
  q[0] = id >> 8; q[1] = id;
  q[2] = 0x01;
  q[5] = 0x01;
  /* question name, as length-prefixed labels */
  ls = 12; o = 13;
  for (i = 0; ; i++) {
    if (name[i] == '.' || name[i] == 0) {
      q[ls] = o - ls - 1;
      ls = o++;
      if (!name[i])
	break;
    } else
      q[o++] = name[i];
  }
  /* here q[ls] is the closing zero-length label and o is just after it */
  q[o++] = 0; q[o++] = 1;	/* type A    */
  q[o++] = 0; q[o++] = 1;	/* class IN  */

  sock = lwip_socket(2 /* PF_INET */, 2 /* SOCK_DGRAM */, 0);
  if (sock < 0)
    return;
  memcpy(&to, &dnssrv, sizeof(to));
  to.sin_family = 2 /* AF_INET */;
  lwip_sendto(sock, q, o, 0, (struct sockaddr *)&to, sizeof(to));
  lwip_close(sock);
}

static void dcnow_thread(void * param)
{
  int ticks = 0;	/* quarter seconds since the last lookup */
  int early = 3;	/* extra lookups at start-up (the first one may be
			   lost while the gateway address is being found) */

  while (dcnow_run) {
    if (ticks <= 0) {
      dcnow_ping();
      if (early > 0) {
	--early;
	ticks = 3 * 4;
      } else
	ticks = DCNOW_PERIOD * 4;
    }
    thd_sleep(250);
    --ticks;
  }
  dcnow_done = 1;
}

static void dcnow_start(void)
{
  if (dcnow_thd)
    return;
  dcnow_run = 1;
  dcnow_done = 0;
  dcnow_thd = thd_create(dcnow_thread, 0);
  if (dcnow_thd)
    thd_set_label(dcnow_thd, "dcnow");
  else
    dcnow_run = 0;
}

static void dcnow_stop(void)
{
  int i;
  if (!dcnow_thd)
    return;
  dcnow_run = 0;
  /* the thread's code lives in this plugin : it must be gone before the
     plugin can be unloaded. */
  for (i = 0; i < 200 && !dcnow_done; i++)
    thd_sleep(50);
  dcnow_thd = 0;
}

int dns(const char * name, struct ip_addr * res)
{
  int i;
  int c;
  unsigned char *ip = (unsigned char *)&res->addr;

  i = 0;
  c = 0;
    
  res->addr = 0;
  while(name[c] != 0) {
    if (name[c] != '.') {
      if (!isdigit(name[c]))
	goto dns;
      ip[i] *= 10;
      ip[i] += name[c] - '0';
    }
    else {
      if (name[c+1] == '.')
	goto dns;
      i++;
    }
    if (i >= 5)
      goto dns;
    c++;
  }

  //res->addr = ntohl(res->addr);

  return 0;

 dns:
  if (dnssrv.sin_port) {
    int err = lwip_gethostbyname(&dnssrv, name, &res->addr) < 0;
    /* keep our own name the most recent lookup (see Dreamcast Now above) */
    dcnow_ping();
    if (err) {
      printf("gethostbyname: Can't look up name");
      return -1;
    } else {
      return 0;
    }
  } else
    return -1;
}



static int find_adaptator(const char * name)
{
  static const char * list[] = {
    "plugins/exe/net/bba/bba.lez",
    "plugins/exe/net/lan/lan.lez",
    0
  };
  static const char * list2[] = {
    0,
    0
  };
  
  char * * l;

  if (name) {
    list2[0] = name;
    l = list2;
  } else
    l = list;

  while (*l) {
    char tmp[256];
    if (*l[0] == '/')
      strcpy(tmp, *l);
    else
      shell_home_path(tmp, sizeof(tmp), *l);
    if (!net_driver_open(tmp))
      break;
    l++;
  }
  
  if (*l) {
    printf("Network driver '%s' loaded and used.\n", *l);
    return 0;
  } else
    return -1;
}



/* Driver init : not much to do. */ 
static int driver_init(any_driver_t *d)
{
  printf("%s_driver_init ... \n", d->name);
  init = 0;

  return 0;

/*  error: */
/*   driver_shutdown(d); */
/*   return -1; */
}

/* Driver shutdown */
static int driver_shutdown(any_driver_t * d)
{
  printf("%s_driver_shutdown ... \n", d->name);

  return 0;
}

static driver_option_t * driver_options(any_driver_t * d, int idx,
                                        driver_option_t * o)
{
  return o;
}


int lua_net_init(lua_State * L)
{
  if (init) {
    goto ok;
  }

  saved_rx_callback = net_input_target;

  printf("net_driver LUA initialized.\n");
  init = 1;
 ok:
  lua_settop(L,1);
  lua_pushnumber(L,1);
  return 1;
}

static int lua_net_shutdown(lua_State * L)
{
  int n;

  if (!init) {
    goto ok;
  }

  dcnow_stop();

  if (lwipinit) {
    httpfs_shutdown();
    tcpfs_shutdown();

    lwip_shutdown_all();
    lwipinit = 0;
  }

  if (netinit) {
    fs_shutdown();

    net_input_set_target(0);

    net_shutdown();

    net_driver_close();

    netinit = 0;
  }

  dma_test(-1);

  init = 0;
  printf("net_driver LUA shutdown.\n");
 ok:
  lua_settop(L,0);
  lua_pushnumber(L,1);
  return 1;
}

extern uint8 eth_mac[6];

static int lua_net_connect(lua_State * L)
{
  int res = -1;
  struct netif_list * listhead;
  uint8 ip[4];

  dbglog_set_level(7);

  if (lua_tostring(L, 1) == NULL || dns(lua_tostring(L, 1), ip)) {
    printf("Syntax error : try net_connect your.ip.add.ress\n");
    return 0;
  }

  if (netinit) {
    if (memcmp(ip, "\0\0\0\0", 4)) {
      /* hack so that we keep dcload connection alive during DHCP re-negotiation */
      printf("Set IP : %d.%d.%d.%d\n", ip[0], ip[1], ip[2], ip[3]);
      eth_setip(ip[0], ip[1], ip[2], ip[3]);
    }
    return 0;
  }

  printf("calling eth_init\n");


  if (!netinit) {
    //net_init();

    old_printk_func = 0;

    if (find_adaptator(lua_tostring(L, 2))) {
      lua_settop(L, 0);
      lua_pushstring(L, "No adaptator recognised");
      return 1;
    }

    net_init();
  }
  netinit = 1;
  
  // Find a device for us
  listhead = net_get_if_list();
  LIST_FOREACH(netif, listhead, if_list) {
    if (netif->flags & NETIF_RUNNING)
      break;
  }
  if (netif == NULL) {
    printf("can't find an active KOS network device\n");
    lua_settop(L, 0);
    lua_pushstring(L, "Can't find an active KOS network device");
    return 1;
  }

  if (netif) {
    uint8 mac[6];
    int i;

    printf("Ethernet adapter initialized succesfully !\n");
    res = 0;

    memcpy(eth_mac, netif->mac_addr, sizeof(eth_mac));
    printf("MAC address : ");
    for (i=0; i<6; i++)
      printf("%x ", (int) eth_mac[i]);
    printf("\n");

    printf("Set IP : %d.%d.%d.%d\n", ip[0], ip[1], ip[2], ip[3]);
    eth_setip(ip[0], ip[1], ip[2], ip[3]);

    net_input_set_target(rx_callback);

    if (!fs_init())
      printf("nfs, httpfs, tcpfs and udpfs initialized succesfully\n");
  }

  return 0;
}

static int lua_net_disconnect(lua_State * L)
{
/*   printf("calling eth_shutdown\n"); */

/*   if (netinit) { */
/*     net_input_set_target(0); */
/*     netinit = 0; */
/*   } */

  return lua_net_shutdown(L);
}

static int lua_net_print(lua_State * L)
{
  const char * msg = lua_tostring(L, 1);
  net_lock();
  sc_write(1, msg, strlen(msg));
  net_unlock();

  return 0;
}

void dummy() { }

static int lua_lwip_init(lua_State * L)
{
  struct ip_addr ip;
  struct ip_addr mask;
  struct ip_addr gw;
  int res = -1;

/*   IP4_ADDR(&ip, 192, 168, 1, 9); */
/*   IP4_ADDR(&mask, 255, 255, 255, 0); */
/*   IP4_ADDR(&gw, 192, 168, 1, 2); */

  if (
      lua_tostring(L, 1)==NULL || dns(lua_tostring(L, 1), &ip) ||
      lua_tostring(L, 2)==NULL || dns(lua_tostring(L, 2), &mask) ||
      lua_tostring(L, 3)==NULL || dns(lua_tostring(L, 3), &gw)
      ) {

    printf("Syntax error : try net_lwip_init your.ip.add.ress 255.255.255.0 your.gate.way.ip\n");
    lua_pushstring(L, "Syntax error : try net_lwip_init your.ip.add.ress 255.255.255.0 your.gate.way.ip\n");
    return 1;
  }

  if (!lwipinit) {
    //lwip_init_mac();
    res = lwip_init_all_static(&ip, &mask, &gw);
    //lwip_init_common("test");
    
    //lwip_init_all();
    
    lwip_cb = net_input_target;
    net_input_set_target(rx_callback);
    
    tcpfs_init() || httpfs_init();
    
    lwipinit = 1;
  } else {
    struct netif *netif;
    // just change ip configuration of interface

    netif = netif_find("kn0");
    if (!netif)
      return 0;
    
    printf("resetting IP of kn0 interface\n");
    memcpy(&netif->ip_addr, &ip, sizeof(ip));
    memcpy(&netif->netmask, &mask, sizeof(ip));
    memcpy(&netif->gw, &gw, sizeof(ip));
  }

  return 0;
}

#include "lwip/sockets.h"
static int lua_gethostbyname(lua_State * L)
{
  struct sockaddr_in dnssrv;
  uint8 ip[4];
  
/*   dnssrv.sin_family = AF_INET; */
/*   dnssrv.sin_port = htons(53); */
/*   if (dns("212.198.2.51", &dnssrv.sin_addr.s_addr)) */
/*     return 0; */
/*   //dnssrv.sin_addr.s_addr = ntohl(dnssrv.sin_addr.s_addr); */
/*   printf("server ip %x\n", dnssrv.sin_addr.s_addr); */

  //if (lwip_gethostbyname(&dnssrv, lua_tostring(L, 1), ip) < 0)
  //if (lwip_gethostbyname2("212.198.2.51", lua_tostring(L, 1), ip) < 0)
  if (dns(lua_tostring(L, 1), ip))
    printf("Can't look up name");
  else {
    printf("ip of '%s' is %d.%d.%d.%d\n", lua_tostring(L, 1),
	   ip[0], ip[1], ip[2], ip[3]);
  }

  return 0;
}

extern struct sockaddr_in dnssrv;
static int lua_resolv(lua_State * L)
{
  dnssrv.sin_port = 0;
  if (dns(lua_tostring(L, 1), &dnssrv.sin_addr.s_addr)) {
    printf("Syntax error : try net_resolv your.dns.add.ress\n");
    return 0;
  }
  dnssrv.sin_family = AF_INET;
  dnssrv.sin_port = htons(53);

  printf("DNS server address set to '%s'\n", lua_tostring(L, 1));

  dcnow_start();

  return 0;
}

/* ------------------------------------------------------------------------
 * Console network settings.
 *
 * Reads the settings saved in the console by a browser or a BBA set-up disc
 * (flash partition 2, logical block 0xE0, the block KallistiOS'
 * flashrom_get_ispcfg() reads). The flash is memory mapped at 0xa0200000.
 * ---------------------------------------------------------------------- */
#define FC_FLASH      0xa0200000
#define FC_PART_START 0x1c000	/* partition 2, 16 KB, same on every console */
#define FC_PART_SIZE  0x4000

static uint8 fc_rd(uint32 off)
{
  return *(volatile uint8 *)(FC_FLASH + off);
}

static uint16 fc_crc16(const uint8 * d, int n)
{
  uint16 rv = 0xffff, t;
  while (n--) {
    t = (rv >> 8) ^ *d++;
    t ^= t >> 4;
    rv = (rv << 8) ^ (t << 12) ^ (t << 5) ^ t;
  }
  return rv ^ 0xffff;
}

/* newest valid copy of logical block 'id' -> b[64] ; 0 if found */
static int fc_get_block(int id, uint8 * b)
{
  static const char magic[] = "KATANA_FLASH____";
  const int bmbytes = 64;
  const uint32 bm = FC_PART_START + FC_PART_SIZE - bmbytes;
  int i, k;

  for (k = 0; k < 16; k++)
    if (fc_rd(FC_PART_START + k) != (uint8)magic[k])
      return -1;
  if ((fc_rd(FC_PART_START + 16) | (fc_rd(FC_PART_START + 17) << 8)) != 2)
    return -1;
  /* bitmap : a 0 bit marks a used block ; blocks are written in order */
  for (i = 0; i < bmbytes * 8; i++)
    if (fc_rd(bm + i / 8) & (0x80 >> (i % 8)))
      break;
  if (i == 0)
    return -1;
  for (i = i - 1; i > 0; i--) {
    uint32 a = FC_PART_START + (uint32)(i + 1) * 64;
    if (a + 64 > bm)
      continue;
    for (k = 0; k < 64; k++)
      b[k] = fc_rd(a + k);
    if ((b[0] | (b[1] << 8)) != id)
      continue;
    if (fc_crc16(b, 62) != (uint16)(b[62] | (b[63] << 8)))
      continue;
    return 0;
  }
  return -1;
}

/* net_flashcfg() : method, ip, mask, gateway, dns1, dns2  (or nothing) */
static int lua_flashcfg(lua_State * L)
{
  static const int at[5] = { 10, 14, 30, 22, 26 }; /* ip mask gw dns1 dns2 */
  uint8 b[64];
  char s[20];
  int i;

  lua_settop(L, 0);
  if (fc_get_block(0xe0, b))
    return 0;

  /* Some consoles have a useless netmask saved (255.255.255.255 has been
     seen : games ignore the field). A netmask must be a run of 1 bits
     followed by 0 bits, not all ones, and must put the gateway on our own
     network. Anything else is replaced by 255.255.255.0. */
  {
    uint32 ip = (b[10] << 24) | (b[11] << 16) | (b[12] << 8) | b[13];
    uint32 nm = (b[14] << 24) | (b[15] << 16) | (b[16] << 8) | b[17];
    uint32 gw = (b[30] << 24) | (b[31] << 16) | (b[32] << 8) | b[33];
    uint32 inv = ~nm;
    if (!nm || !inv || (inv & (inv + 1)) || (gw && ((ip ^ gw) & nm))) {
      b[14] = b[15] = b[16] = 255;
      b[17] = 0;
    }
  }
  lua_pushnumber(L, b[6]);	/* 0 dial-up, 1 DHCP, 2 PPPoE, 3 static */
  for (i = 0; i < 5; i++) {
    const uint8 * p = b + at[i];
    sprintf(s, "%d.%d.%d.%d", p[0], p[1], p[2], p[3]);
    lua_pushstring(L, s);
  }
  return 6;
}

/* net_has_bba() : 1 if a Broadband Adapter is fitted.
 *
 * Reading the adapter's ID with nothing in the expansion port leaves G2 bus
 * error flags set, and the sound chip is on the same bus. So the check runs
 * with interrupts off, waits for the G2 FIFO before each read and clears
 * only the error flags it caused. Done once ; the answer is remembered.
 */
static int lua_has_bba(lua_State * L)
{
  static const char id[17] = "GAPSPCI_BRIDGE_2";
  static int known = -1;
  volatile uint32 * const isterr = (volatile uint32 *)0xa05f6908;
  volatile uint32 * const ffst = (volatile uint32 *)0xa05f688c;

  if (known < 0) {
    uint32 before;
    int i, n, ok = 1, old = irq_disable();

    before = *isterr;
    for (i = 0; i < 16; i++) {
      for (n = 100000; (*ffst & 0x11) && --n; )
	;
      if (*(volatile uint8 *)(0xa1001400 + i) != (uint8)id[i]) {
	ok = 0;
	break;
      }
    }
    *isterr = *isterr & ~before;	/* writing 1 clears a flag */
    irq_restore(old);
    known = ok;
  }

  lua_settop(L, 0);
  if (!known)
    return 0;
  lua_pushnumber(L, 1);
  return 1;
}

static int lua_dma(lua_State * L)
{
  dma_test((int)lua_tonumber(L, 1));
  return 0;
}

static luashell_command_description_t driver_commands[] = {

  /* Internal commands */
  {
    /* long names, short names and topic */
    DRIVER_NAME"_driver_init", 0, 0,
    /* usage */
    DRIVER_NAME"_driver_init() : "
    "INTERNAL ; initialize lua side of " DRIVER_NAME " driver.",
    /* function */
    SHELL_COMMAND_C, lua_net_init
  },

  {
    /* long names, short names and topic */
    DRIVER_NAME"_driver_shutdown", 0, 0,
    /* usage */
    DRIVER_NAME"_driver_shutdown() : "
    "INTERNAL ; shutdown lua side of " DRIVER_NAME " driver.",
    /* function */
    SHELL_COMMAND_C, lua_net_shutdown
  },

  {
    /* long names, short names and topic */
    DRIVER_NAME"_lwip_init", 0, 0,
    /* usage */
    DRIVER_NAME"_lwip(). Initialize the tcp/ip stack.",
    /* function */
    SHELL_COMMAND_C, lua_lwip_init,
  },

  {
    /* long names, short names and topic */
    DRIVER_NAME"_connect", 0, 0,
    /* usage */
    DRIVER_NAME"_connect(ip) : "
    "Connect the BBA and set its ip (string of the form '192.168.1.9').",
    /* function */
    SHELL_COMMAND_C, lua_net_connect
  },

  {
    /* long names, short names and topic */
    DRIVER_NAME"_disconnect", 0, 0,
    /* usage */
    DRIVER_NAME"_disconnect() : "
    "Disconnect the BBA.",
    /* function */
    SHELL_COMMAND_C, lua_net_disconnect
  },

  {
    /* long names, short names and topic */
    DRIVER_NAME"_print", 0, 0,
    /* usage */
    DRIVER_NAME"_print(message) : "
    "Send a console message through the BBA. (just for testing)",
    /* function */
    SHELL_COMMAND_C, lua_net_print
  },

  {
    /* long names, short names and topic */
    DRIVER_NAME"_gethostbyname", 0, 0,
    /* usage */
    DRIVER_NAME"_gethostbyname(name) : "
    "Query DNS for ip address.",
    /* function */
    SHELL_COMMAND_C, lua_gethostbyname
  },

  {
    /* long names, short names and topic */
    DRIVER_NAME"_resolv", 0, 0,
    /* usage */
    DRIVER_NAME"_resolv(addr) : "
    "Set DNS server address.",
    /* function */
    SHELL_COMMAND_C, lua_resolv
  },

  {
    /* long names, short names and topic */
    DRIVER_NAME"_flashcfg", 0, 0,
    /* usage */
    DRIVER_NAME"_flashcfg() : "
    "Read the network settings saved in the console. Returns method "
    "(0 dial-up, 1 DHCP, 2 PPPoE, 3 static), ip, mask, gateway, dns1, dns2 "
    "or nothing if no settings are saved.",
    /* function */
    SHELL_COMMAND_C, lua_flashcfg
  },

  {
    /* long names, short names and topic */
    DRIVER_NAME"_has_bba", 0, 0,
    /* usage */
    DRIVER_NAME"_has_bba() : "
    "Returns 1 if a Broadband Adapter is fitted (safe to call on any console).",
    /* function */
    SHELL_COMMAND_C, lua_has_bba
  },

  {
    /* long names, short names and topic */
    DRIVER_NAME"_dma", 0, 0,
    /* usage */
    DRIVER_NAME"_dma() : "
    "Test DMA.",
    /* function */
    SHELL_COMMAND_C, lua_dma
  },


 
  {0},                                    /* end of the command list */
};

any_driver_t net_driver =
  {

    0,                     /**< Next driver                     */
    EXE_DRIVER,            /**< Driver type                     */      
    0x0100,                /**< Driver version                  */
    DRIVER_NAME,           /**< Driver name                     */
    "Vincent Penne",       /**< Driver authors                  */
    "Network support."     /**< Description                     */
    ,
    0,                     /**< DLL handler                     */
    driver_init,           /**< Driver init                     */
    driver_shutdown,       /**< Driver shutdown                 */
    driver_options,        /**< Driver options                  */
    driver_commands,       /**< Lua shell commands              */
  
  };

EXPORT_DRIVER(net_driver)
