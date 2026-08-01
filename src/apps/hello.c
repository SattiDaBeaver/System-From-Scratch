/* src/apps/hello.c
 * Smoke test for the C toolchain: printf (newlib+UART wiring), integer
 * division (confirms -mno-div lowers to libgcc soft-div, not the
 * hardware's unimplemented div/rem opcode), and malloc/free (confirms
 * the _sbrk heap wiring).
 */

#include <stdio.h>
#include <stdlib.h>

/* volatile so a/b aren't compile-time constants -- otherwise gcc just
 * folds the division at compile time and no div/mod call ever gets
 * emitted, which would defeat the point of this check. */
volatile int a = 17, b = 5;

int main(void) {
    printf("hello from RV32IM\n");

    printf("17 / 5 = %d, 17 %% 5 = %d\n", a / b, a % b);

    int *buf = malloc(4 * sizeof(int));
    for (int i = 0; i < 4; i++) buf[i] = i * i;
    printf("squares: %d %d %d %d\n", buf[0], buf[1], buf[2], buf[3]);
    free(buf);

    return 0;
}
