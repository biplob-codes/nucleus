#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/stat.h>
#include "utils.h"
#define CGROUP_ROOT "/sys/fs/cgroup"
#define MAX_MEMORY  "67108864"
int init_cgroup(pid_t pid)
{
	char *controls = "+memory";
	int result = write_file(CGROUP_ROOT "/cgroup.subtree_control", controls,
				strlen(controls));
	if (result < 0) {
		perror("write to controller failed");
		return 1;
	}
	char root_path[300];
	size_t root_path_size = sizeof(root_path);
	int n = snprintf(root_path, sizeof(root_path),
			 CGROUP_ROOT "/nucleus-%d", pid);
	if (n < 0 || (size_t)n >= root_path_size) {
		perror("failed to construct root path");
		return 1;
	}
	if (mkdir(root_path, 0755) == -1) {
		perror("failed to create the root folder for cgroup");
		return 1;
	}
	char memory_path[400];
	size_t memory_path_size = sizeof(memory_path);

	n = snprintf(memory_path, memory_path_size, "%s/memory.max", root_path);
	if (n < 0 || (size_t)n >= memory_path_size) {
		perror("failed to construct memory path");
		return 1;
	}
	result = write_file(memory_path, MAX_MEMORY, strlen(MAX_MEMORY));
	if (result < 0) {
		perror("setting max memory failed");
		return 1;
	}
	char swap_path[400];
	size_t swap_path_size = sizeof(swap_path);
	n = snprintf(swap_path, swap_path_size, "%s/memory.swap.max",
		     root_path);
	if (n < 0 || (size_t)n >= swap_path_size) {
		perror("failed to construct swap path");
		return 1;
	}
	result = write_file(swap_path, "0", strlen("0"));
	if (result < 0) {
		perror("swap write failed");
		return 1;
	}
	char proc_path[400];
	size_t proc_path_size = sizeof(proc_path);
	n = snprintf(proc_path, proc_path_size, "%s/cgroup.procs", root_path);
	if (n < 0 || (size_t)n >= proc_path_size) {
		perror("failed to construct proc path");
		return 1;
	}
	char pid_str[16];
	size_t pid_str_size = sizeof(pid_str);
	n = snprintf(pid_str, pid_str_size, "%d", pid);
	if (n < 0 || (size_t)n >= pid_str_size) {
		perror("failed to construct pid_str");
		return 1;
	}
	result = write_file(proc_path, pid_str, strlen(pid_str));
	if (result < 0) {
		perror("write pid");
		return 1;
	}
	return 0;
}