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
#include "netns.h"
#define STACK_SIZE (1024 * 1024)

int main(int argc, char *argv[])
{
	char *hostname = NULL;
	char *root_fs = NULL;
	Config conf;
	parse(argc, argv, &hostname, &root_fs);
	setup_config(&conf, &hostname, &root_fs);
	signal(SIGPIPE, SIG_IGN);
	char *stack = malloc(STACK_SIZE);
	if (!stack) {
		perror("malloc failed for stack");
		return 1;
	}
	char *stack_top = stack + STACK_SIZE;
	int flags = CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWNS | SIGCHLD |
		    CLONE_NEWNET;

	if (pipe2(conf.sync_fd, O_CLOEXEC) == -1) {
		perror("pipe for fd");
		return 1;
	}

	pid_t pid = clone(container, stack_top, flags, &conf);
	if (pid == -1) {
		perror("failed to clone");
		return 1;
	}
	close(conf.sync_fd[0]);
	int result = init_cgroup(pid);
	if (result != 0) {
		perror("initializing cgroup");
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		cleanup_cgroup(pid);
		return 1;
	}
	result = init_netns(pid);
	if (result != 0) {
		perror("initializing network namespace");
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		cleanup_cgroup(pid);
		return 1;
	}
	if (write(conf.sync_fd[1], "x", 1) == -1) {
		perror("write to fd");
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		cleanup_cgroup(pid);
		free(stack);
		return 1;
	}
	close(conf.sync_fd[1]);
	int status;
	waitpid(pid, &status, 0);
	free(stack);
	cleanup_cgroup(pid);
	if (WIFEXITED(status))
		return WEXITSTATUS(status);

	if (WIFSIGNALED(status))
		return (WTERMSIG(status) + 128);
}