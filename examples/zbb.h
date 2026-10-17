#ifndef ZBB_H
#define ZBB_H

/*
 * zbb.h - Zbb CPOP / CTZ for the RV32IM soft CPU (src/bitmanip.v)
 *
 * Only these two Zbb instructions are implemented, so do NOT build with
 * -march=rv32im_zbb: gcc would then also emit clz, andn, min, rol, rev8, ...
 * which this CPU does not decode. Keep -march=rv32im and call these instead;
 * .insn lets the rv32im assembler encode them anyway.
 *
 *   cpop rd, rs1 : OP-IMM, funct3 = 001, imm = 0x602
 *   ctz  rd, rs1 : OP-IMM, funct3 = 001, imm = 0x601   (32 for rs1 == 0)
 */

#include <stdint.h>

static inline uint32_t zbb_cpop32(uint32_t x) {
    uint32_t r;
    __asm__ (".insn i 0x13, 1, %0, %1, 0x602" : "=r"(r) : "r"(x));
    return r;
}

static inline uint32_t zbb_ctz32(uint32_t x) {
    uint32_t r;
    __asm__ (".insn i 0x13, 1, %0, %1, 0x601" : "=r"(r) : "r"(x));
    return r;
}

static inline uint32_t zbb_cpop64(uint64_t x) {
    return zbb_cpop32((uint32_t)x) + zbb_cpop32((uint32_t)(x >> 32));
}

/* 64 for x == 0, like ctz itself returns 32 */
static inline uint32_t zbb_ctz64(uint64_t x) {
    uint32_t lo = (uint32_t)x;
    return lo ? zbb_ctz32(lo) : 32 + zbb_ctz32((uint32_t)(x >> 32));
}

#endif
