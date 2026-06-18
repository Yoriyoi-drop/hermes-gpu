set project_dir [file normalize [file dirname [info script]]/../synth/vivado]
set project_name hermes_gpu
set output_dir [file normalize [file dirname [info script]]/../synth/output]

open_project $project_dir/$project_name.xpr

read_xdc [file normalize [file dirname [info script]]/../constraints/hermes.xdc]

set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

synth_design -top hermes_gpu -part xc7a200tfbg676-2
write_checkpoint -force $output_dir/post_synth.dcp
report_timing_summary -file $output_dir/timing_post_synth.rpt
report_utilization -file $output_dir/utilization_post_synth.rpt

puts "Synthesis completed. Reports in $output_dir"
close_project
