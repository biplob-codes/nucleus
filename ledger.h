#if !defined(LEDGER_H)
#define LEDGER_H
typedef struct {
	char *stack;
	int sync_fd[2];
	char root_cgroup_dir[300];
	char container_cgroup_dir[300];
	char host_side_veth[100];
	int org_ip_frwrd_v;
} ledger;
void clean_up(ledger *ld);
#endif // LEDGER_H
