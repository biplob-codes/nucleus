#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include "utils.h"
#include "nuc_error.h"
#define CGROUP_ROOT	   "/sys/fs/cgroup/nucleus"
#define CGROUP_CONTROLLERS "/sys/fs/cgroup/nucleus/cgroup.controllers"
#define MAX_MEMORY	   "67108864"
#define MAX_PIDS	   "128"
#define MAX_CPU		   "50000 100000"
typedef struct {
	char *resource;
	char *limit;

} cgroup;

int cgroup_ctrl_status()
{
	char *resources[3] = {"memory", "pids", "cpu"};
	FILE *f = fopen(CGROUP_CONTROLLERS, "rb");
	if (!f) {
		return -1;
	}
	char buf[256];
	size_t n = fread(buf, 1, (sizeof(buf) - 1), f);
	buf[n] = '\0';
	fclose(f);
	for (int i = 0; i < 3; i++) {
		if (!strstr(buf, resources[i])) {
			errno = NUC_CGROUP_CTRL_ERR;
			return -1;
		}
	}
	return 0;
}
int build_cgroup_ctrl_path(char *buf, size_t size_buf, char *resource,
			   char *root_path)
{
	int n = snprintf(buf, size_buf, "%s/%s", root_path, resource);
	if (n < 0 || (size_t)n >= size_buf) {
		errno = NUC_FORMAT_ERR;
		return -1;
	}
	return 0;
}
int set_limits(char *root_path)
{
	cgroup cgroup_table[] = {
		{"memory.max", MAX_MEMORY},
		{"memory.swap.max", "0"},
		{"cpu.max", MAX_CPU},
		{"pids.max", MAX_PIDS},
		{NULL, NULL},
	};
	for (int i = 0; cgroup_table[i].resource != NULL; i++) {
		char buf[400];
		int result = build_cgroup_ctrl_path(
			buf, sizeof(buf), cgroup_table[i].resource, root_path);
		if (result == -1)
			return result;
		result = write_file(buf, cgroup_table[i].limit,
				    strlen(cgroup_table[i].limit));
		if (result == -1)
			return result;
	}
	return 0;
}
int init_cgroup(pid_t pid)
{
	int result = mkdir(CGROUP_ROOT, 0755);
	if (result == -1 && errno != EEXIST) {
		return -1;
	}
	result = cgroup_ctrl_status();
	if (result == -1)
		goto delete_cgroup_dir;
	char *controls = "+memory +pids +cpu";
	result = write_file(CGROUP_ROOT "/cgroup.subtree_control", controls,
			    strlen(controls));
	if (result == -1)
		goto delete_cgroup_dir;

	char root_path[300];
	size_t root_path_size = sizeof(root_path);
	int n = snprintf(root_path, sizeof(root_path), CGROUP_ROOT "/nuc-%d",
			 pid);
	if (n < 0 || (size_t)n >= root_path_size) {
		errno = NUC_FORMAT_ERR;
		goto delete_cgroup_dir;
	}
	if (mkdir(root_path, 0755) == -1)
		goto delete_cgroup_dir;
	result = set_limits(root_path);
	if (result == -1)
		goto delete_root_path;

	char pid_str[16];
	size_t pid_str_size = sizeof(pid_str);
	n = snprintf(pid_str, pid_str_size, "%d", pid);
	if (n < 0 || (size_t)n >= pid_str_size) {
		errno = NUC_FORMAT_ERR;
		goto delete_root_path;
	}
	char proc_path[400];
	result = build_cgroup_ctrl_path(proc_path, sizeof(proc_path),
					"cgroup.procs", root_path);
	if (result == -1)
		goto delete_root_path;
	result = write_file(proc_path, pid_str, strlen(pid_str));
	if (result == -1)
		goto delete_root_path;
	return 0;
delete_root_path:
	rmdir(root_path);
delete_cgroup_dir:
	rmdir(CGROUP_ROOT);
	return -1;
}
void cleanup_cgroup(pid_t pid)
{
	char cg_path[400];
	size_t cg_path_size = sizeof(cg_path);
	int n = snprintf(cg_path, cg_path_size, CGROUP_ROOT "/nuc-%d", pid);
	if (n < 0 || (size_t)n >= cg_path_size) {
		fprintf(stderr, "failed to construct cgroup path");
	}
	if (rmdir(cg_path) == -1) {
		fprintf(stderr, "failed to clean cgroup dir");
	}
}