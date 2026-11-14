#if !defined(NUC_ERROR_H)
#define NUC_ERROR_H
enum nuc_error {
	NUC_E_MISSING_FLAGS = 1000,
	NUC_INVALID_ROOTFS_PATH,
	NUC_FORMAT_ERR,
};
char *err_str(int e);
void nuc_err_report(char *step, int e);
#endif // NUC_ERROR_H
