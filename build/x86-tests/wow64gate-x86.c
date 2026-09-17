/* A 32-bit program that must never run.
 *
 * It exists to exercise the ml805 gate in NtCreateUserProcess, which refuses a
 * 32-bit image before a child, a socket or a parent wait exists. WOW64 needs
 * the guest's process parameters in the low 2GB and iOS hands out no address
 * space below 4GB at all, so there is no device, prefix or setting that makes
 * a 32-bit guest work here -- the point of the gate is to say so cleanly
 * instead of freezing the desktop on a parent parked forever.
 *
 * It prints, so that a run where the gate FAILED to fire is distinguishable
 * from one where it fired: this line in the log means the refusal did not
 * happen. Silence plus a [proc-gate] ml805 line is the pass.
 */
#include <stdio.h>

int main(void)
{
    printf("[wow64gate] this should be unreachable on iOS: a 32-bit guest ran\n");
    fflush(stdout);
    return 0;
}
