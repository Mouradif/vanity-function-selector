#include <metal_stdlib>
using namespace metal;

// ---- File-scope constants (OK in Metal; not allowed as locals) ----
constant uint64_t KECCAK_RC[24] = {
    0x0000000000000001UL,0x0000000000008082UL,0x800000000000808aUL,0x8000000080008000UL,
    0x000000000000808bUL,0x0000000080000001UL,0x8000000080008081UL,0x8000000000008009UL,
    0x000000000000008aUL,0x0000000000000088UL,0x0000000080008009UL,0x000000008000000aUL,
    0x000000008000808bUL,0x800000000000008bUL,0x8000000000008089UL,0x8000000000008003UL,
    0x8000000000008002UL,0x8000000000000080UL,0x000000000000800aUL,0x800000008000000aUL,
    0x8000000080008081UL,0x8000000000008080UL,0x0000000080000001UL,0x8000000080008008UL
};

constant ushort KECCAK_PI[24] = {
    10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1
};

// ---- Keccak-256 (Ethereum) ----
inline uint64_t rol64(uint64_t x, uint s) { return (x << s) | (x >> (64 - s)); }

inline void keccak_f1600(thread uint64_t S[25]) {
    for (uint round = 0; round < 24; ++round) {
        // θ
        uint64_t C[5];
        for (uint x = 0; x < 5; ++x)
            C[x] = S[x] ^ S[x+5] ^ S[x+10] ^ S[x+15] ^ S[x+20];

        uint64_t D0 = C[4] ^ rol64(C[1], 1);
        uint64_t D1 = C[0] ^ rol64(C[2], 1);
        uint64_t D2 = C[1] ^ rol64(C[3], 1);
        uint64_t D3 = C[2] ^ rol64(C[4], 1);
        uint64_t D4 = C[3] ^ rol64(C[0], 1);

        S[0] ^= D0;  S[5] ^= D0;  S[10] ^= D0; S[15] ^= D0; S[20] ^= D0;
        S[1] ^= D1;  S[6] ^= D1;  S[11] ^= D1; S[16] ^= D1; S[21] ^= D1;
        S[2] ^= D2;  S[7] ^= D2;  S[12] ^= D2; S[17] ^= D2; S[22] ^= D2;
        S[3] ^= D3;  S[8] ^= D3;  S[13] ^= D3; S[18] ^= D3; S[23] ^= D3;
        S[4] ^= D4;  S[9] ^= D4;  S[14] ^= D4; S[19] ^= D4; S[24] ^= D4;

        // ρ + π (cycle-based; matches Zig)
        uint64_t last = S[1];
        uint rotc = 0; // mod 64
        for (uint i = 0; i < 24; ++i) {
            uint idx = KECCAK_PI[i];
            uint64_t tmp = S[idx];
            rotc = (rotc + i + 1) & 63;
            S[idx] = rol64(last, rotc);
            last = tmp;
        }

        // χ
        for (uint y = 0; y < 25; y += 5) {
            uint64_t a0 = S[y+0], a1 = S[y+1], a2 = S[y+2], a3 = S[y+3], a4 = S[y+4];
            S[y+0] = a0 ^ ((~a1) & a2);
            S[y+1] = a1 ^ ((~a2) & a3);
            S[y+2] = a2 ^ ((~a3) & a4);
            S[y+3] = a3 ^ ((~a4) & a0);
            S[y+4] = a4 ^ ((~a0) & a1);
        }

        // ι
        S[0] ^= KECCAK_RC[round];
    }
}

// Single-block Keccak-256 for Ethereum (rate = 136), pad10*1 (0x01 ... 0x80)
inline void keccak256_eth(const thread uchar* msg, uint len, thread uchar out32[32]) {
    thread uint64_t S[25];
    for (uint i = 0; i < 25; ++i) S[i] = 0;

    const uint RATE = 136;

    // Absorb
    uint i = 0;
    for (; i + 8 <= len; i += 8) {
        uint64_t v =
            ((uint64_t)msg[i+0])       |
            ((uint64_t)msg[i+1] << 8)  |
            ((uint64_t)msg[i+2] << 16) |
            ((uint64_t)msg[i+3] << 24) |
            ((uint64_t)msg[i+4] << 32) |
            ((uint64_t)msg[i+5] << 40) |
            ((uint64_t)msg[i+6] << 48) |
            ((uint64_t)msg[i+7] << 56);
        S[i/8] ^= v;
    }
    uint64_t last = 0;
    uint rem = len - i;
    for (uint b = 0; b < rem; ++b) last |= ((uint64_t)msg[i+b]) << (8*b);
    S[i/8] ^= last;

    // pad10*1 within the block
    S[len/8]      ^= (uint64_t)0x01ULL << ((len % 8) * 8);
    S[(RATE-1)/8] ^= (uint64_t)0x80ULL << (((RATE-1) % 8) * 8);

    keccak_f1600(S);

    // Squeeze 32 bytes (little-endian lanes)
    for (uint j = 0; j < 32; ++j) {
        uint64_t lane = S[j/8];
        out32[j] = (uchar)((lane >> (8 * (j % 8))) & 0xFF);
    }
}

// ---- Vanity selector search kernel ----
struct SearchIn {
    uint  must_be_one;
    uint  must_be_zero;
    uint  prefix_len;
    uint  args_len;
    uint  alphabet_len;
    uint  max_suffix_len;
    ulong start_index;
    ulong total_space;
};

struct SearchOut {
    atomic_uint found;   // 0 = not found, 1 = found
    uint  selector;
    uint  suffix_len;
    uint  _pad_;
    uchar suffix[32];
};

kernel void vanity_selector(
    device const uchar*         prefix   [[buffer(0)]],
    device const uchar*         args     [[buffer(1)]],
    device const uchar*         alphabet [[buffer(2)]],
    device const SearchIn&      cfg      [[buffer(3)]],
    device volatile SearchOut*  out      [[buffer(4)]],
    uint3 tid3 [[thread_position_in_grid]],
    uint3 tpg3 [[threads_per_grid]]
) {
    if (atomic_load_explicit(&out->found, memory_order_relaxed) != 0) return;

    // Flatten indices
    ulong threads_per_grid = (ulong)tpg3.x * (ulong)tpg3.y * (ulong)tpg3.z;
    ulong tid = (ulong)tid3.z * ((ulong)tpg3.x * (ulong)tpg3.y)
              + (ulong)tid3.y * (ulong)tpg3.x
              + (ulong)tid3.x;

    thread uchar sig[256];  // prefix + suffix + '(' + args + ')'
    thread uchar hash[32];

    // Copy prefix once
    for (uint i = 0; i < cfg.prefix_len; ++i) sig[i] = prefix[i];
    const uint head = cfg.prefix_len;

    ulong counter = cfg.start_index + tid;
    const ulong end = cfg.start_index + cfg.total_space;
    const ulong N = (ulong)cfg.alphabet_len;

    while (counter < end) {
        if (atomic_load_explicit(&out->found, memory_order_relaxed) != 0) return;

        // Determine suffix length bucket (1..max_suffix_len)
        uint L = 1;
        ulong base = 0;
        ulong span = N; // N^1
        while (L < cfg.max_suffix_len && counter >= base + span) {
            base += span;
            span *= N;
            L += 1;
        }
        ulong idx = counter - base;

        // Build suffix (LS digit first)
        for (uint i = 0; i < L; ++i) {
            ulong digit = idx % N; idx /= N;
            sig[head + i] = alphabet[digit];
        }

        // Compose full signature
        uint pos = head + L;
        sig[pos++] = '(';
        for (uint i = 0; i < cfg.args_len; ++i) sig[pos++] = args[i];
        sig[pos++] = ')';
        uint sig_len = pos;

        // Hash
        keccak256_eth(sig, sig_len, hash);

        // Selector = bytes 31..28 (big-endian display)
        uint sel = ((uint)hash[0] << 24) | ((uint)hash[1] << 16) | ((uint)hash[2] << 8) | (uint)hash[3];

        // Mask check
        if ( ((sel & cfg.must_be_one) == cfg.must_be_one) && ((sel & cfg.must_be_zero) == 0) ) {
            if (atomic_exchange_explicit(&out->found, 1, memory_order_relaxed) == 0) {
                out->selector   = sel;
                out->suffix_len = L;
                uint cpy = (L < 32u) ? L : 32u;
                for (uint i = 0; i < cpy; ++i) out->suffix[i] = sig[head + i];
            }
            return;
        }

        counter += threads_per_grid;
    }
}
