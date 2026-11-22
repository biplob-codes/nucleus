#include <unistd.h>
#include "ledger.h"
#if !defined(CGROUP_H)
#define CGROUP_H
int init_cgroup(pid_t pid, ledger *ld);
void cleanup_cgroup(pid_t pid);
#endif // CGROUP_H
