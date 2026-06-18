set part_name xc7a200tfbg676-2
set project_name hermes_gpu
set project_dir [file normalize [file dirname [info script]]/../synth/vivado]

create_project $project_name $project_dir -part $part_name -force

set rtl_dir [file normalize [file dirname [info script]]/../rtl]

read_verilog -sv [glob $rtl_dir/*.sv]
read_verilog -sv [glob $rtl_dir/*.svh]

set_property SOURCE_SET sources_1 [get_filesets simset_1]
close_project
puts "Project $project_name created at $project_dir"
