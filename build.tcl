# Gowin EDA Tcl Build Script for RISK-V CPU

# Define project name and directory
set proj_name "riscv_cpu"
set proj_dir "gowin_project"
set device_pn "GW5A-LV25MG121NC1/I0"

# Save the root working directory before opening the project
set root_dir [pwd]
set proj_path [file join $root_dir $proj_dir]
set proj_file [file join $proj_path $proj_name $proj_name.gprj]

# Open the existing project
open_project $proj_file

# open_project changes the working directory to the folder holding the .gprj,
# and that is also where Gowin writes its impl/ output tree. The RTL loads its
# ROM with $readmemh("examples/loop55.hex"), a path relative to the repository
# root (the same one the simulations use), so stage a copy of the hex next to
# the project rather than cd'ing back to the root - a cd would work for the
# $readmemh but would also drag the whole impl/ tree out to the repo root.
#
# Without a resolvable hex the $readmemh only warns
# ("WARN (EX3988) : Cannot open file"), the ROM reads back as all zeros, and the
# synthesiser then constant-folds the entire CPU away - ALU, decoder, register
# file, both memories and the UART all reported as "swept in optimizing". The
# build still succeeds and produces a bitstream containing just the LED blinker,
# so the board looks alive while running no CPU at all.
# Take the hex path from the INIT_FILE default in fpga_top.v rather than
# repeating it here, so the staged copy can never drift from what the RTL asks
# $readmemh for.
set fh [open [file join $root_dir src fpga_top.v] r]
set fpga_top_src [read $fh]
close $fh

if {![regexp {parameter\s+INIT_FILE\s*=\s*"([^"]+)"} $fpga_top_src -> init_hex]} {
    error "Could not find the INIT_FILE parameter default in src/fpga_top.v"
}

set src_hex [file join $root_dir $init_hex]

if {![file exists $src_hex]} {
    error "ROM image not found: $src_hex - build it first (see README)"
}

file mkdir [file join [pwd] examples]
file copy -force $src_hex [file join [pwd] $init_hex]
puts "Staged ROM image: [file join [pwd] $init_hex]"

# Set Top Module and options
set_option -top_module fpga_top
set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_cpu_as_gpio 1

# Run Synthesis
run syn

# Run Place & Route (PnR)
run pnr

# Exit
exit
