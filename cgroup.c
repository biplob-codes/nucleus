#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/stat.h>
#include "utils.h"
#define CGROUP_ROOT "/sys/fs/cgroup"
int init_cgroup(pid_t pid)
{
	char *msg = "+memory";
	int result = write_file(CGROUP_ROOT "/cgroup.subtree_control", msg,
				strlen(msg));
	if (result < 0) {
		perror("write to controller failed");
		return 1;
	}
	char cg_nucleus_path[300];
	snprintf(cg_nucleus_path, sizeof(cg_nucleus_path),
		 CGROUP_ROOT "/nucleus-%d", pid);
	if (mkdir(cg_nucleus_path, 0755) == -1) {
		perror("mkdir");
		return 1;
	}
	char cg_mem_path[400];
	snprintf(cg_mem_path, sizeof(cg_mem_path), "%s/memory.max",
		 cg_nucleus_path);
	char *max_mem = "8388608";
	result = write_file(cg_mem_path, max_mem, strlen(max_mem));
	if (result < 0) {
		perror("setting max memory failed");
		return 1;
	}
	char swap_path[400];
	snprintf(swap_path, sizeof(swap_path), "%s/memory.swap.max",
		 cg_nucleus_path);
	result = write_file(swap_path, "0", strlen("0"));
	if (result < 0) {
		perror("swap write failed");
		return 1;
	}
	char proc_path[400];
	snprintf(proc_path, sizeof(proc_path), "%s/cgroup.procs",
		 cg_nucleus_path);
	char pid_str[16];
	snprintf(pid_str, sizeof(pid_str), "%d", pid);
	result = write_file(proc_path, pid_str, strlen(pid_str));
	if (result < 0) {
		perror("write pid");
		return 1;
	}
	return 0;
}