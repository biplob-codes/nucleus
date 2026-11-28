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
#include <errno.h>
#include "parser.h"
#include "config.h"
#include "container.h"
#include "cgroup.h"
#include "netns.h"
#include "nuc_error.h"
#include "ledger.h"
#define STACK_SIZE (1024 * 1024)
int main(int argc, char *argv[])
{
	typedef struct {
		Config conf;
		ledger ld;
	} ctx_struct;
	ctx_struct ctx = {.ld = {NULL, {-1, -1}, {0}, {0}, {0}, -1}};
	char *hostname = NULL;
	char *root_fs = NULL;
	int rs = parse(argc, argv, &hostname, &root_fs);
	if (rs == -1) {
		nuc_err_report("parse", errno);
		return 1;
	}
	rs = setup_config(&ctx.conf, &hostname, &root_fs);
	if (rs == -1) {
		nuc_err_report("setup config", errno);
		return 1;
	}
	signal(SIGPIPE, SIG_IGN);
	char *stack = malloc(STACK_SIZE);
	if (!stack) {
		nuc_err_report("malloc", errno);
		return 1;
	}
	ctx.ld.stack = stack;
	char *stack_top = stack + STACK_SIZE;
	int flags = CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWNS | SIGCHLD |
		    CLONE_NEWNET;

	if (pipe2(ctx.ld.sync_fd, O_CLOEXEC) == -1) {
		nuc_err_report("pipe2", errno);
		goto clean;
	}
	pid_t pid = clone(container, stack_top, flags, &ctx);
	if (pid == -1) {
		nuc_err_report("clone", errno);
		goto clean;
	}
	close(ctx.ld.sync_fd[0]);
	ctx.ld.sync_fd[0] = -1;
	int result = init_cgroup(pid, &ctx.ld);
	if (result == -1) {
		nuc_err_report("init cgroups", errno);
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		goto clean;
	}
	// TODO: clean netns when rewriting it.
	result = init_netns(pid, &ctx.ld);
	if (result != 0) {
		perror("initializing network namespace");
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		goto clean;
	}
	if (write(ctx.ld.sync_fd[1], "x", 1) == -1) {
		nuc_err_report("write to pipe", errno);
		kill(pid, SIGKILL);
		waitpid(pid, NULL, 0);
		goto clean;
	}
	close(ctx.ld.sync_fd[1]);
	ctx.ld.sync_fd[1] = -1;
	int status;
	waitpid(pid, &status, 0);
	clean_up(&ctx.ld);
	if (WIFEXITED(status))
		return WEXITSTATUS(status);

	if (WIFSIGNALED(status))
		return (WTERMSIG(status) + 128);
clean:
	clean_up(&ctx.ld);
	return 1;
}