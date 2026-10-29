#ifndef MP_H
#define MP_H

// Starting and stopping the second hart (src/cpu_top.v, NUM_HARTS = 2).
//
// Hart 1 is held in reset until hart 0 starts it. It then begins at the reset
// vector like hart 0 did; tools/crt0.S gives it its own stack and calls
// hart_main(1). A program that starts hart 1 must be linked with
// tools/link_mp.ld, because data loads from the ROM read as 0 while hart 1 runs.
//
// The harts share the data RAM without caches, and every access is performed
// in program order, so a flag written by one hart after its data is enough to
// hand that data to the other. There are no atomic instructions yet: a
// variable written by both harts needs a lock built some other way.

#define HART_RUN    ((volatile unsigned int *)0x80000200)   // bit h: hart h runs

// Runs on every hart other than 0 (defined by the program).
void hart_main(unsigned int hartid);

static inline void hart_start(unsigned int hart) {
    *HART_RUN |= 1u << hart;
}

// Puts the hart back in reset; hart_start runs it from the beginning again.
static inline void hart_stop(unsigned int hart) {
    *HART_RUN &= ~(1u << hart);
}

#endif // MP_H
