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
#include "cgroup.h"
#define STACK_SIZE (1024 * 1024)

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
	int result = init_cgroup(pid);
	if (result != 0) {
		perror("initializing cgroup");
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