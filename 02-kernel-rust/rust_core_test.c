// SPDX-License-Identifier: GPL-2.0
//
// BEREICH 2.2 — Userspace-Testprogramm für /dev/rust_core
// ===========================================================================
// Demonstriert alle ioctl-Operationen des Rust-Moduls. Die Kommandonummern
// MÜSSEN exakt mit rust_core.rs übereinstimmen ('R', Nummern 0x80..0x83).
//
//   cc rust_core_test.c -o rust_core_test
//   sudo ./rust_core_test
// ===========================================================================
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/ioctl.h>

#define RUST_CORE_IOCTL_MAGIC 'R'
#define RUST_CORE_GET_VALUE _IOR(RUST_CORE_IOCTL_MAGIC, 0x80, int32_t)
#define RUST_CORE_SET_VALUE _IOW(RUST_CORE_IOCTL_MAGIC, 0x81, int32_t)
#define RUST_CORE_GET_OPENS _IOR(RUST_CORE_IOCTL_MAGIC, 0x82, uint64_t)
#define RUST_CORE_HELLO     _IO(RUST_CORE_IOCTL_MAGIC, 0x83)

int main(void) {
    int fd = open("/dev/rust_core", O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "open(/dev/rust_core): %s\n", strerror(errno));
        return 1;
    }

    if (ioctl(fd, RUST_CORE_HELLO) < 0)
        perror("HELLO");

    int32_t set = 42;
    if (ioctl(fd, RUST_CORE_SET_VALUE, &set) < 0)
        perror("SET_VALUE");

    int32_t got = 0;
    if (ioctl(fd, RUST_CORE_GET_VALUE, &got) < 0)
        perror("GET_VALUE");
    printf("value = %d (erwartet 42)\n", got);

    uint64_t opens = 0;
    if (ioctl(fd, RUST_CORE_GET_OPENS, &opens) < 0)
        perror("GET_OPENS");
    printf("open()-Aufrufe seit Laden des Moduls = %llu\n",
           (unsigned long long)opens);

    close(fd);
    return 0;
}
