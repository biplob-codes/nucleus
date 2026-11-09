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
int pivot_root(const char *new_root, const char *put_old)
{
	return syscall(SYS_pivot_root, new_root, put_old);
}
int main(int argc, char *argv[])
{
	char *hostname = NULL;
	char *root_fs = NULL;
	Config conf;
	parse(argc, argv, &hostname, &root_fs);
	setup_config(&conf, &hostname, &root_fs);
	printf("Hello from Nucleus\n");
	if (unshare(CLONE_NEWPID) == -1) {
		perror("failed to create new pid namespace");
		return 1;
	}
	pid_t pid = fork();
	if (pid < 0) {
		perror("fork failed.");
		return 1;
	}
	if (pid == 0) {
		printf("we are in the child process. detaching the hostname\n");
		if (unshare(CLONE_NEWUTS) == -1) {
			perror("hostname detachment failed");
			return 1;
		}
		if (unshare(CLONE_NEWNS) == -1) {
			perror("cloning mount table failed");
			return 1;
		}
		if (mount("", "/", NULL, MS_REC | MS_PRIVATE, NULL) == -1) {
			perror("failed to make the child mount table private");
			return 1;
		}
		char *olddir = "/olddir";
		char *old_fs =
			malloc(strlen(conf.root_fs) + strlen(olddir) + 1);
		if (old_fs == NULL) {
			perror("malloc failed");
			return 1;
		}
		strcpy(old_fs, conf.root_fs);
		strcat(old_fs, olddir);

		if (mount(conf.root_fs, conf.root_fs, NULL, MS_BIND | MS_REC,
			  0) == -1) {
			perror("binding root dir failed");
			return 1;
		}
		if (mkdir(old_fs, 0755) == -1) {
			if (errno != EEXIST) {
				perror("failed to create old dir");
				return 1;
			}
		}

		if (pivot_root(conf.root_fs, old_fs) == -1) {
			perror("mounting new root failed");
			return 1;
		}
		free(old_fs);
		chdir("/");
		if (mount("nucleusproc", "/proc", "proc", 0, NULL) == -1) {
			perror("mounting failed");
			return 1;
		}
		umount2(olddir, MNT_DETACH);

		size_t len = strlen(conf.hostname);
		if (sethostname(conf.hostname, len) == -1) {
			perror("sethostname failed");
			return (1);
		}
		printf("hostname set successfully.");
		execlp("/bin/sh", "sh", NULL);
		perror("exec failed");
		return (1);
	}

	int status;
	waitpid(pid, &status, 0);
	if (WIFEXITED(status))
		return WEXITSTATUS(status);

	if (WIFSIGNALED(status))
		return (WTERMSIG(status) + 128);
}