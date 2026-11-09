/* machlookup NAME: exit 0 if a Mach service NAME is registered in this
   user's bootstrap namespace. sandbox-test.sh runs it, unsandboxed, while
   the sandboxed IME holds its IMKServer connection name. */
#include <servers/bootstrap.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: machlookup NAME\n");
        return 2;
    }
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, argv[1], &port);
    printf("%s: %s\n", argv[1], kr == KERN_SUCCESS ? "registered" : "not registered");
    return kr == KERN_SUCCESS ? 0 : 1;
}
