set dir_ooc_out ${dir_output}/ooc/${ooc_top}
file mkdir $dir_ooc_out

read_verilog [ glob $dir_bsv_gen/*.v ]
read_xdc ${dir_ooc_scripts}/bsv_ooc_module_common.xdc -mode out_of_context
synth_design -part $part -top $ooc_top -mode out_of_context -flatten_hierarchy none
write_checkpoint -force ${dir_ooc_out}/${ooc_top}.dcp



report_timing_summary -report_unconstrained -warn_on_violation -file $dir_ooc_out/post_synth_timing_summary.rpt
check_timing -override_defaults no_clock -file $dir_ooc_out/post_synth_check_timing.rpt
report_design_analysis -logic_level_dist_paths $max_net_path_num -logic_level_distribution -file $dir_ooc_out/post_synth_design_logic_level_dist.rpt
xilinx::designutils::report_failfast -max_paths 5000 -detailed_reports synth -file $dir_ooc_out/post_synth_failfast.rpt
report_drc -file $dir_ooc_out/post_synth_drc.rpt
report_methodology -file $dir_ooc_out/post_synth_methodology.rpt
report_timing -max $max_net_path_num -slack_less_than 0 -file $dir_ooc_out/post_synth_timing.rpt
report_utilization -file $dir_ooc_out/post_synth_util.rpt; # -cells -pblocks
