# Gowin EDA Tcl Build Script for RISK-V CPU

# Define project name and directory
set proj_name "riscv_cpu"
set proj_dir "gowin_project"
set device_pn "GW5A-LV25MG121NC1/I0"

# Save the root working directory before create_project changes it
set root_dir [pwd]

# Create project
create_project -name $proj_name -dir $proj_dir -pn $device_pn -device_version "A" -force

# Add Verilog Source Files
add_file -type verilog "$root_dir/src/fpga_top.v"
add_file -type verilog "$root_dir/src/cpu_top.v"
add_file -type verilog "$root_dir/src/instruction_decoder.v"
add_file -type verilog "$root_dir/src/alu.v"
add_file -type verilog "$root_dir/src/register_file.v"
add_file -type verilog "$root_dir/src/imm_gen.v"
add_file -type verilog "$root_dir/src/program_counter.v"
add_file -type verilog "$root_dir/src/instruction_memory.v"
add_file -type verilog "$root_dir/src/control_unit.v"
add_file -type verilog "$root_dir/src/data_memory.v"
add_file -type verilog "$root_dir/src/uart_tx.v"


# Add Constraints
add_file -type cst "$root_dir/constraints/tang_primer_25k.cst"
add_file -type sdc "$root_dir/constraints/timing.sdc"

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
