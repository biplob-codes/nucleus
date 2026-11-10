#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <unistd.h>
#include <sched.h>
#include <sys/wait.h>
#include <stdlib.h>
#include "parser.h"
#include "config.h"
#include "container.h"
#define STACK_SIZE (1024 * 1024)

// int argc, char *argv[]
int main()
{
	// char *hostname = NULL;
	// char *root_fs = NULL;
	// Config conf;
	// parse(argc, argv, &hostname, &root_fs);
	// setup_config(&conf, &hostname, &root_fs);
	char *stack = malloc(STACK_SIZE);
	if (!stack) {
		perror("malloc failed for stack");
		return 1;
	}
	char *stack_top = stack + STACK_SIZE;
	int flags = CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWNS | SIGCHLD;
	int fd[2];
	if (pipe(fd) == -1) {
		perror("pipe for fd");
		return 1;
	}
	pid_t pid = clone(container, stack_top, flags, fd);
	close(fd[0]);
	if (write(fd[1], "x", 1) == -1) {
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