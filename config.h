#if !defined(CONFIG_H)
#define CONFIG_H

typedef struct {
	char *hostname;
	char *root_fs;
} Config;
void setup_config(Config *conf, char **hostname, char **fs);
#endif // CONFIG_H
