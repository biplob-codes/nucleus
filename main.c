#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <unistd.h>
#include <sched.h>
#include <sys/wait.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include "parser.h"
#include "config.h"
#include "container.h"
#include "utils.h"
#define STACK_SIZE  (1024 * 1024)
#define CGROUP_ROOT "/sys/fs/cgroup"
int main(int argc, char *argv[])
{
	char *hostname = NULL;
	char *root_fs = NULL;
	Config conf;
	parse(argc, argv, &hostname, &root_fs);
	setup_config(&conf, &hostname, &root_fs);
	char *stack = malloc(STACK_SIZE);
	if (!stack) {
		perror("malloc failed for stack");
		return 1;
	}
	char *stack_top = stack + STACK_SIZE;
	int flags = CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWNS | SIGCHLD;
	if (pipe(conf.sync_fd) == -1) {
		perror("pipe for fd");
		return 1;
	}

	pid_t pid = clone(container, stack_top, flags, &conf);
	close(conf.sync_fd[0]);
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
	if (write(conf.sync_fd[1], "x", 1) == -1) {
		perror("write to fd");
		return 1;
	}
	printf("Hello from Nucleus\n");

	int status;
	waitpid(pid, &status, 0);
	free(stack);
	if (WIFEXITED(status))
		return WEXITSTATUS(status);

	if (WIFSIGNALED(status))
		return (WTERMSIG(status) + 128);
}