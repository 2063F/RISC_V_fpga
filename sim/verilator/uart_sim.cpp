// =============================================================================
// uart_sim.cpp - cpu_top を Verilator でサイクル精度シミュレーションし、UART を
//                標準入出力につなぐハーネス (iverilog の数百倍速い)
// =============================================================================
// 使い方:
//   uart_sim <program.hex は Verilator ビルド時に指定> [--profile syms.txt]
//            [--max-cycles N] < input.txt
// 入力は1行ずつ、CPU の出力が "> " か ": " で終わった(=入力待ちになった)ときに送る。
// 入力を送り切って次の入力待ちになったら終了する。
// "MOVE" / "AI plays" 行が出るたびに、直前の入力を送り終えてからの経過サイクル数を
// 標準エラーに出す。
// --profile には `nm -n --defined-only prog.elf` の出力を渡すと関数別サイクル数を出す。
// =============================================================================
#include "Vcpu_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include <algorithm>
#include <iostream>

static const int BIT = 434; // 50 MHz / 115200

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *prof_path = nullptr;
    unsigned long long max_cycles = 20ULL * 1000 * 1000 * 1000;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--profile") && i + 1 < argc) prof_path = argv[++i];
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], 0, 10);
    }

    std::vector<std::string> lines;
    for (std::string l; std::getline(std::cin, l);) lines.push_back(l + "\r");
    size_t next_line = 0;

    Vcpu_top *top = new Vcpu_top;
    top->clk = 0; top->rst_n = 0; top->uart_rx_pin = 1; top->mem_read_data = 0;

    std::map<unsigned, unsigned long long> pc_hist;

    // TX decoder state
    int tx_state = -1; long tx_cnt = 0; int tx_bit = 0; unsigned tx_byte = 0;
    std::string out_tail, cur_line;
    // RX driver state
    std::string sending; size_t send_pos = 0; long rx_cnt = 0; int rx_bit = -1;
    unsigned long long sent_done_cycle = 0;
    bool waiting_input = false; unsigned long long idle_since = 0;

    for (unsigned long long cyc = 0; cyc < max_cycles; cyc++) {
        top->rst_n = cyc > 10;
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
        if (prof_path) pc_hist[top->debug_pc]++;

        // ---- TX: decode CPU output
        int pin = top->uart_tx_pin;
        if (tx_state < 0) {
            if (!pin) { tx_state = 0; tx_cnt = BIT / 2; tx_bit = 0; tx_byte = 0; }
        } else if (--tx_cnt <= 0) {
            if (tx_state == 0) { tx_state = 1; tx_cnt = BIT; }
            else if (tx_bit < 8) { tx_byte |= (unsigned)pin << tx_bit; tx_bit++; tx_cnt = BIT; }
            else {
                tx_state = -1;
                char c = (char)tx_byte;
                if (c != '\r') { putchar(c); fflush(stdout); }
                if (c == '\n') {
                    if (cur_line.rfind("MOVE", 0) == 0 || cur_line.rfind("AI plays", 0) == 0)
                        fprintf(stderr, "[cycles since input: %llu (%.1f ms)]\n",
                                cyc - sent_done_cycle, (cyc - sent_done_cycle) / 50000.0);
                    cur_line.clear();
                } else cur_line += c;
                out_tail += c;
                if (out_tail.size() > 4) out_tail.erase(0, out_tail.size() - 4);
                size_t n = out_tail.size();
                waiting_input = n >= 2 && out_tail[n - 1] == ' ' &&
                                (out_tail[n - 2] == '>' || out_tail[n - 2] == ':');
                idle_since = cyc;
            }
        }

        // ---- RX: feed input lines when the program is waiting for input
        if (rx_bit < 0 && send_pos >= sending.size()) {
            if (waiting_input && tx_state < 0 && cyc - idle_since > 2000) {
                if (next_line >= lines.size()) break;
                sending = lines[next_line++]; send_pos = 0; waiting_input = false;
            }
        }
        if (rx_bit < 0 && send_pos < sending.size()) { rx_bit = 0; rx_cnt = BIT; top->uart_rx_pin = 0; }
        else if (rx_bit >= 0 && --rx_cnt <= 0) {
            unsigned char b = sending[send_pos];
            if (rx_bit < 8) { top->uart_rx_pin = (b >> rx_bit) & 1; rx_bit++; rx_cnt = BIT; }
            else if (rx_bit == 8) { top->uart_rx_pin = 1; rx_bit++; rx_cnt = BIT; }
            else { rx_bit = -1; send_pos++; if (send_pos == sending.size()) sent_done_cycle = cyc; }
        }
    }
    printf("\n");

    if (prof_path) {
        // nm -n 出力: "addr type name"
        std::vector<std::pair<unsigned, std::string>> syms;
        FILE *f = fopen(prof_path, "r");
        char name[256], type; unsigned addr;
        while (f && fscanf(f, "%x %c %255s", &addr, &type, name) == 3)
            if (type == 't' || type == 'T') syms.push_back({addr, name});
        if (f) fclose(f);
        std::map<std::string, unsigned long long> fn;
        unsigned long long total = 0;
        for (auto &kv : pc_hist) {
            unsigned pc = kv.first - 4; // debug_pc = ex_pc + 4
            std::string nm = "?";
            for (auto &s : syms) { if (s.first <= pc) nm = s.second; else break; }
            fn[nm] += kv.second; total += kv.second;
        }
        std::vector<std::pair<unsigned long long, std::string>> v;
        for (auto &kv : fn) v.push_back({kv.second, kv.first});
        std::sort(v.rbegin(), v.rend());
        if (getenv("PROFILE_PCS")) {
            std::vector<std::pair<unsigned long long, unsigned>> pv;
            for (auto &kv : pc_hist) pv.push_back({kv.second, kv.first - 4});
            std::sort(pv.rbegin(), pv.rend());
            fprintf(stderr, "---- hot PCs ----\n");
            for (size_t i = 0; i < pv.size() && i < 60; i++)
                fprintf(stderr, "%08x %llu\n", pv[i].second, pv[i].first);
        }
        fprintf(stderr, "---- profile (cycles) ----\n");
        for (size_t i = 0; i < v.size() && i < 20; i++)
            fprintf(stderr, "%6.2f%% %12llu %s\n", 100.0 * v[i].first / total, v[i].first, v[i].second.c_str());
    }
    delete top;
    return 0;
}
