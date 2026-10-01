# usb_hid_host (vendored)

USB HID host core by nand2mario: https://github.com/nand2mario/usb_hid_host
(commit 678b013, Apache License 2.0 - see LICENSE).

Low-speed (1.5 Mbps) USB keyboards, mice and gamepads; needs a 12 MHz clock
(src/gowin/gowin_pll_usb.v, taken from the same repository's Tang Primer 25K
example).

Local changes: array declarations `regs [7]` / `dat[8]` rewritten as
`[0:6]` / `[0:7]` so the file builds in Verilog-2001 mode; and `usb_hid_host_rom.v` loads its ROM image from
`src/usb_hid_host/usb_hid_host_rom.hex` (relative to the repository root, like
the CPU ROM) instead of the current directory. build.tcl stages the file next
to the Gowin project.
