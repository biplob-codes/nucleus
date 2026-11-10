#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <unistd.h>
#include <sched.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <errno.h>
#include <stdlib.h>
#include "parser.h"
#include "config.h"
#define STACK_SIZE (1024 * 1024)
int pivot_root(const char *new_root, const char *put_old)
{
	return syscall(SYS_pivot_root, new_root, put_old);
}
int child(void *arg)
{
	int *fd = (int *)arg;
	char buf;
	if (read(fd[0], &buf, 1) != 1) {
		perror("read from fd failed");
		exit(EXIT_FAILURE);
	}

	if (mount("", "/", NULL, MS_REC | MS_PRIVATE, NULL) == -1) {
		perror("failed to make the child mount table private");
		return 1;
	}
	char *olddir = "/olddir";
	char *root_fs = "/home/biplobcodes/projects/alpine-rootfs";
	char *old_fs = malloc(strlen(root_fs) + strlen(olddir) + 1);
	if (old_fs == NULL) {
		perror("malloc failed");
		return 1;
	}
	strcpy(old_fs, root_fs);
	strcat(old_fs, olddir);

	if (mount(root_fs, root_fs, NULL, MS_BIND | MS_REC, 0) == -1) {
		perror("binding root dir failed");
		return 1;
	}
	if (mkdir(old_fs, 0755) == -1) {
		if (errno != EEXIST) {
			perror("failed to create old dir");
			return 1;
		}
	}

	if (pivot_root(root_fs, old_fs) == -1) {
		perror("mounting new root failed");
		return 1;
	}
	free(old_fs);
	if (chdir("/") == -1) {
		perror("failed to change the working directory");
		return 1;
	}

	if (mount("nucleusproc", "/proc", "proc", 0, NULL) == -1) {
		perror("mounting failed");
		return 1;
	}
	if (umount2(olddir, MNT_DETACH) == -1) {
		perror("failed to unmount the old dir");
		return 1;
	}
	if (rmdir(olddir) == -1) {
		perror("failed to delete the olddir directory");
		return 1;
	}
	size_t len = strlen("ilovekiara");
	if (sethostname("ilovekiara", len) == -1) {
		perror("sethostname failed");
		return (1);
	}
	printf("hostname set successfully\n");
	execlp("/bin/sh", "sh", NULL);
	perror("exec failed");
	return (1);
}
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
	pid_t pid = clone(child, stack_top, flags, fd);
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