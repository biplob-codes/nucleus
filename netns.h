#include <stdlib.h>
#include "ledger.h"
#if !defined(NETNS_H)
#define NETNS_H

int init_netns(pid_t pid, ledger *ld);

#endif // NETNS_H
