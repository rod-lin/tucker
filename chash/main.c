#include <stdio.h>

#include "mine.h"
#include "test.h"
#include "sha256.h"
#include "common.h"

int main()
{
    do_test();

    byte_t raw[] =
        "\x00\x00\x00\x00\x6f\xe2\x8c\x0a" "\xb6\xf1\xb3\x72\xc1\xa6\xa2\x46"
        "\xae\x63\xf7\x4f\x93\x1e\x83\x65" "\xe1\x5a\x08\x9c\x68\xd6\x19\x00"
        "\x00\x00\x00\x00\xf6\xa8\xfc\xb4" "\x03\xb8\x64\xbd\x65\x30\xb1\x6e"
        "\xba\xe8\xdf\x20\x47\x6b\x81\x01" "\xc8\x91\x11\x15\xef\x27\x70\xd6"
        "\xba\x44\x00\x3a\x29\xab\x5f\x49" "\xff\xff\x00\x1d";

    hash256_t target =
        "\x00\x00\x00\x00\x00\x00\x00\x00" "\x00\x00\x00\x00\x00\x00\x00\x00"
        "\x00\x00\x00\x00\x00\x00\x00\x00" "\x00\x00\xff\xff\x00\x00\x00\x00";

    do_mine(raw, sizeof(raw) - 1, target, 4);

    return 0;
}
