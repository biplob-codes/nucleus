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
#include "parser.h"
int pivot_root(const char *new_root, const char *put_old)
{
	return syscall(SYS_pivot_root, new_root, put_old);
}
int main(int argc, char *argv[])
{
	char *hostname = NULL;
	parse(argc, argv, &hostname);
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

		char root_dir[] = "/home/biplobcodes/projects/alpine-rootfs";
		char old_dir[] =
			"/home/biplobcodes/projects/alpine-rootfs/olddir";
		if (mount(root_dir, root_dir, NULL, MS_BIND | MS_REC, 0) ==
		    -1) {
			perror("binding root dir failed");
			return 1;
		}
		if (mkdir(old_dir, 0755) == -1) {
			if (errno != EEXIST) {
				perror("failed to create old dir");
				return 1;
			}
		}

		if (pivot_root(root_dir, old_dir) == -1) {
			perror("mounting new root failed");
			return 1;
		}
		chdir("/");
		if (mount("nucleusproc", "/proc", "proc", 0, NULL) == -1) {
			perror("mounting failed");
			return 1;
		}
		umount2("/olddir", MNT_DETACH);
		if (hostname == NULL) {
			hostname = "nucleus";
		}
		size_t len = strlen(hostname);
		if (sethostname(hostname, len) == -1) {
			perror("sethostname failed");
			return (1);
		}
		printf("hostname set successfully.");
		execlp("/bin/sh", "sh", NULL);
		perror("exec failed");
		return (1);
	}
	waitpid(pid, NULL, 0);
	return 0;
}