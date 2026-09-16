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
