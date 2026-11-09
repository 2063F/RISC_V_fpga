// model_test.h - Target macros for riscv-arch-test 2.7.4 on this CPU
//
// Used by sim/arch_test/run_arch_test.py. The tests run on a one-hart
// cpu_top in sim/arch_test/tb_arch_test.v; the testbench dumps the signature
// from the data RAM once the test reaches rvmodel_halt.

#ifndef _MODEL_TEST_H
#define _MODEL_TEST_H

#define RVMODEL_DATA_SECTION

// The data (test inputs and the signature area) lives in RAM, and its
// initial image in ROM right behind the code (see link.ld). Copy it across
// before the test starts; every register used here is reset by
// RVTEST_CODE_BEGIN afterwards.
#define RVMODEL_BOOT                    \
    la   t0, _data_lma;                 \
    la   t1, _data_start;               \
    la   t2, _data_end;                 \
1:  bgeu t1, t2, 2f;                    \
    lw   t3, 0(t0);                     \
    sw   t3, 0(t1);                     \
    addi t0, t0, 4;                     \
    addi t1, t1, 4;                     \
    j    1b;                            \
2:

// The testbench watches the PC for this loop.
#define RVMODEL_HALT                    \
    .global rvmodel_halt;               \
rvmodel_halt:                           \
    j    rvmodel_halt;

#define RVMODEL_DATA_BEGIN              \
    .align 4;                           \
    .global begin_signature;            \
begin_signature:

#define RVMODEL_DATA_END                \
    .align 4;                           \
    .global end_signature;              \
end_signature:

#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_SP, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_SP, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

// None of the tests used here raise interrupts.
#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

#endif
