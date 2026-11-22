#include "ledger.h"
#include <stdlib.h>
#include <unistd.h>
void clean_up(ledger *ld)
{
	if (ld->container_cgroup_dir[0] != '\0') {
		rmdir(ld->container_cgroup_dir);
	}
	if (ld->root_cgroup_dir[0] != '\0') {
		rmdir(ld->root_cgroup_dir);
	}
	if (ld->sync_fd[0] != -1) {
		close(ld->sync_fd[0]);
		ld->sync_fd[0] = -1;
	}
	if (ld->sync_fd[1] != -1) {
		close(ld->sync_fd[1]);
		ld->sync_fd[1] = -1;
	}
	if (ld->stack != NULL)
		free(ld->stack);
}