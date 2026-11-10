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
	int file_fd = open(CGROUP_ROOT "/cgroup.subtree_control", O_WRONLY);
	char *msg = "+memory";
	if (write(file_fd, msg, strlen(msg)) == -1) {
		perror("write failed");
		return 1;
	}
	close(file_fd);
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
	int mem_fd = open(cg_mem_path, O_WRONLY);
	char *max_mem = "8388608";
	if (write(mem_fd, max_mem, strlen(max_mem)) == -1) {
		perror("mem write failed");
		return 1;
	}
	close(mem_fd);
	char swap_path[400];
	snprintf(swap_path, sizeof(swap_path), "%s/memory.swap.max",
		 cg_nucleus_path);
	int swap_fd = open(swap_path, O_WRONLY);
	if (write(swap_fd, "0", 1) == -1) {
		perror("swap write failed");
		return 1;
	}
	close(swap_fd);
	char proc_path[400];
	snprintf(proc_path, sizeof(proc_path), "%s/cgroup.procs",
		 cg_nucleus_path);
	char pid_str[16];
	snprintf(pid_str, sizeof(pid_str), "%d", pid);
	int proc_fd = open(proc_path, O_WRONLY);
	if (write(proc_fd, pid_str, strlen(pid_str)) == -1) {
		perror("write pid");
		return 1;
	}
	close(proc_fd);
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