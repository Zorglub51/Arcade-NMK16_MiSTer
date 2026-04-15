// Serialize operators for fx68k's unpacked SystemVerilog structs.
// Verilator's --savable can't auto-generate operator<< / operator>> for
// unpacked structs, so we provide raw-byte operators here. Force-included
// into every generated translation unit via `-CFLAGS "-include ..."`.
//
// Safe because these three struct types are POD (plain old data) in Verilator's
// codegen — just wide bitfields with logic-typed members.

#pragma once
#include "Vnmk16_phase4_top___024root.h"
#include "verilated_save.h"

#define FX68K_SAVE_STRUCT(T)                                           \
    inline VerilatedSerialize&   operator<<(VerilatedSerialize& os,    \
                                           const T& s) {               \
        os.write(&s, sizeof(s));                                       \
        return os;                                                     \
    }                                                                  \
    inline VerilatedDeserialize& operator>>(VerilatedDeserialize& is,  \
                                           T& s) {                     \
        is.read(&s, sizeof(s));                                        \
        return is;                                                     \
    }

FX68K_SAVE_STRUCT(Vnmk16_phase4_top_s_clks__struct__0)
FX68K_SAVE_STRUCT(Vnmk16_phase4_top_s_nanod__struct__0)
FX68K_SAVE_STRUCT(Vnmk16_phase4_top_s_irdecod__struct__0)

#undef FX68K_SAVE_STRUCT
