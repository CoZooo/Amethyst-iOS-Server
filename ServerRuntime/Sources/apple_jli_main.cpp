/*
 * OpenJDK's Apple launcher starts Java on a new pthread and calls the process
 * main symbol again. A .NET for iOS host therefore renames its generated main
 * to ais_host_main and lets this file route the two entry paths.
 */

extern "C" int ais_jli_reentry_is_active(void);
extern "C" int ais_jli_reentry_launch(int argc, char **argv);

extern int ais_host_main(int argc, char **argv);

__attribute__((visibility("default"))) int main(int argc, char **argv)
{
    if (ais_jli_reentry_is_active() != 0) {
        return ais_jli_reentry_launch(argc, argv);
    }

    return ais_host_main(argc, argv);
}
