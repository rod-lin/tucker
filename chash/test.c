#include <string.h>

#include "test.h"
#include "sha256.h"

struct {
    byte_t *dat;
    size_t size;
    char *expected;
} tests[] = {
    { "hello", 5, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" },
    { "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0", 64, "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b" },

    { "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0", 63, "c7723fa1e0127975e49e62e753db53924c1bd84b8ac1ac08df78d09270f3d971" },

    { "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0"
      "\0\0\0\0\0\0\0\0\0", 65, "98ce42deef51d40269d542f5314bef2c7468d401ad5d85168bfab4c0108f75f7" },

    { "\1\1\1\1\1\1\1\1"
      "\1\1\1\1\1\1\1\1"
      "\1\1\1\1\1\1\1\1"
      "\1\1\1\1\1\1\1\1"
      "\1\1\1\1\1\1\1\1"
      "\1\1\1\1\1\1\1\1"
      "\1\1\1\1\1\1\1\1"
      "\1\1\1\1\1\1\1\1", 64, "7c8975e1e60a5c8337f28edf8c33c3b180360b7279644a9bc1af3c51e6220bf5" },
};

void do_test()
{
    int i;
    hash256_t exp, hash;

    for (i = 0; i < sizeof(tests) / sizeof(*tests); i++) {
        sha256(tests[i].dat, tests[i].size, hash);
        read_hash256(tests[i].expected, exp);

        if (memcmp(exp, hash, sizeof(hash)) != 0) {
            fprintf(stderr, "test error for case %d\n", i);
            print_hash256(exp);
            print_hash256(hash);
        }
    }
}
