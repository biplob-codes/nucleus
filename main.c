#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <unistd.h>
#include <sched.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <string.h>
int main()
{
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
		if (mount("nucleusproc", "/proc", "proc", 0, NULL) == -1) {
			perror("mounting failed");
			return 1;
		}
		printf("new hostname:");
		char buf[64];
		if (scanf("%63s", buf) == 1) {
			size_t len = strlen(buf);
			if (sethostname(buf, len) == -1) {
				perror("sethostname failed");
				return (1);
			}
			printf("hostname set successfully.");
			execlp("bash", "bash", NULL);
			perror("exec failed");
			return (1);
		}
	}
	waitpid(pid, NULL, 0);
	return 0;
}