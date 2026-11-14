#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include "utils.h"
#include "nuc_error.h"
#define CGROUP_ROOT "/sys/fs/cgroup"
#define MAX_MEMORY  "67108864"
#define MAX_PIDS    "128"
#define MAX_CPU	    "50000 100000"
int init_cgroup(pid_t pid)
{
	char *controls = "+memory +pids +cpu";
	int result = write_file(CGROUP_ROOT "/cgroup.subtree_control", controls,
				strlen(controls));
	if (result == -1)
		return result;
	char root_path[300];
	size_t root_path_size = sizeof(root_path);
	int n = snprintf(root_path, sizeof(root_path),
			 CGROUP_ROOT "/nucleus-%d", pid);
	if (n < 0 || (size_t)n >= root_path_size) {
		errno = NUC_FORMAT_ERR;
		return -1;
	}
	if (mkdir(root_path, 0755) == -1)
		return -1;

	char memory_path[400];
	size_t memory_path_size = sizeof(memory_path);

	n = snprintf(memory_path, memory_path_size, "%s/memory.max", root_path);
	if (n < 0 || (size_t)n >= memory_path_size) {
		errno = NUC_FORMAT_ERR;
		return -1;
	}
	result = write_file(memory_path, MAX_MEMORY, strlen(MAX_MEMORY));
	if (result == -1)
		return result;
	char swap_path[400];
	size_t swap_path_size = sizeof(swap_path);
	n = snprintf(swap_path, swap_path_size, "%s/memory.swap.max",
		     root_path);
	if (n < 0 || (size_t)n >= swap_path_size) {
		errno = NUC_FORMAT_ERR;
		return -1;
	}
	result = write_file(swap_path, "0", strlen("0"));
	if (result == -1)
		return result;
	char proc_path[400];
	size_t proc_path_size = sizeof(proc_path);
	n = snprintf(proc_path, proc_path_size, "%s/cgroup.procs", root_path);
	if (n < 0 || (size_t)n >= proc_path_size) {
		errno = NUC_FORMAT_ERR;
		return -1;
	}
	char pids_path[400];
	size_t pids_path_size = sizeof(pids_path);
	n = snprintf(pids_path, pids_path_size, "%s/pids.max", root_path);
	if (n < 0 || (size_t)n >= pids_path_size) {
		errno = NUC_FORMAT_ERR;
		return -1;
		;
	}
	result = write_file(pids_path, MAX_PIDS, strlen(MAX_PIDS));
	if (result == -1)
		return result;
	char cpu_path[400];
	size_t cpu_path_size = sizeof(cpu_path);
	n = snprintf(cpu_path, cpu_path_size, "%s/cpu.max", root_path);
	if (n < 0 || (size_t)n >= cpu_path_size) {
		errno = NUC_FORMAT_ERR;
		return -1;
	}
	result = write_file(cpu_path, MAX_CPU, strlen(MAX_CPU));
	if (result == -1)
		return result;
	char pid_str[16];
	size_t pid_str_size = sizeof(pid_str);
	n = snprintf(pid_str, pid_str_size, "%d", pid);
	if (n < 0 || (size_t)n >= pid_str_size) {
		errno = NUC_FORMAT_ERR;
		return -1;
	}
	result = write_file(proc_path, pid_str, strlen(pid_str));
	if (result == -1)
		return result;
	return 0;
}
void cleanup_cgroup(pid_t pid)
{
	char cg_path[400];
	size_t cg_path_size = sizeof(cg_path);
	int n = snprintf(cg_path, cg_path_size, CGROUP_ROOT "/nucleus-%d", pid);
	if (n < 0 || (size_t)n >= cg_path_size) {
		fprintf(stderr, "failed to construct cgroup path");
	}
	if (rmdir(cg_path) == -1) {
		fprintf(stderr, "failed to clean cgroup dir");
	}
}