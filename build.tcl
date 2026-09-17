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

# open_project changes the working directory to the .gprj folder. The RTL loads
# its ROM image with $readmemh("examples/loop55.hex"), a path relative to the
# repository root (the same path the simulations use), so restore the root here.
#
# Without this the $readmemh silently fails with only a warning
# ("WARN (EX3988) : Cannot open file"), the ROM reads back as all zeros, and the
# synthesiser then constant-folds the entire CPU away - ALU, decoder, register
# file, both memories and the UART are all reported as "swept in optimizing".
# The build still succeeds and produces a bitstream containing just the LED
# blinker, so the board looks alive while running no CPU at all.
cd $root_dir

# Fail loudly if the ROM image is missing, rather than synthesising an empty CPU.
set init_hex "examples/loop55.hex"
if {![file exists $init_hex]} {
    error "ROM image not found: [file join [pwd] $init_hex] - build it first (see README)"
}

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
