/* src/libc_port/syscalls.c
 * Newlib syscall stubs for bare-metal RV32IM. libnosys.a provides these
 * symbols already but as no-ops/error stubs -- linking syscalls.o ahead
 * of -lnosys makes these definitions win instead.
 *
 * _write is what makes printf visible: same UART TX protocol
 * bootloader.asm's uart_tx_byte implements by hand (poll TX_busy at
 * status bit 0, write byte, repeat), see docs/01_architecture.md's
 * memory map for the 0x10000000/0x10000008 addresses.
 */

#include <sys/stat.h>
#include <errno.h>

#define UART_TX     (*(volatile unsigned int *)0x10000000)
#define UART_STATUS (*(volatile unsigned int *)0x10000008)
#define UART_TX_BUSY 0x1

extern char end[];  /* from link.ld */

static char *heap_ptr = end;

void *_sbrk(int incr) {
    char *prev = heap_ptr;
    heap_ptr += incr;
    return prev;
}

int _write(int file, char *ptr, int len) {
    (void)file;
    for (int i = 0; i < len; i++) {
        while (UART_STATUS & UART_TX_BUSY) {}
        UART_TX = (unsigned int)(unsigned char)ptr[i];
    }
    return len;
}

void _exit(int code) {
    (void)code;
    while (1) {}
}

int _close(int file) {
    (void)file;
    return -1;
}

int _fstat(int file, struct stat *st) {
    (void)file;
    st->st_mode = S_IFCHR;
    return 0;
}

int _isatty(int file) {
    (void)file;
    return 1;
}

int _lseek(int file, int ptr, int dir) {
    (void)file; (void)ptr; (void)dir;
    return 0;
}

int _read(int file, char *ptr, int len) {
    (void)file; (void)ptr; (void)len;
    return 0;
}
