#if !defined(LEDGER_H)
#define LEDGER_H
typedef struct {
	char *stack;
	int sync_fd[2];
	char root_cgroup_dir[300];
	char container_cgroup_dir[300];
	char host_side_veth[100];
} ledger;
void clean_up(ledger *ld);
#endif // LEDGER_H
