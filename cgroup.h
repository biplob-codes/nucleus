#include <unistd.h>
#if !defined(CGROUP_H)
#define CGROUP_H
typedef struct {
	char *stack;
	int sync_fd[2];
	char root_cgroup_dir[300];
	char container_cgroup_dir[300];
} ledger;
int init_cgroup(pid_t pid, ledger *ld);
void cleanup_cgroup(pid_t pid);

#endif // CGROUP_H
