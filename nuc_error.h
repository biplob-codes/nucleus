#if !defined(NUC_ERROR_H)
#define NUC_ERROR_H
enum nuc_error {
	NUC_E_MISSING_FLAGS = 1000,
};
char *err_str(int e);

#endif // NUC_ERROR_H
